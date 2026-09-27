from __future__ import annotations

import base64
import hashlib
import http.client
import json
import secrets
import socket
import time
from typing import Any, Callable
from urllib.parse import urlsplit

from .accessibility import ChatTranscriptUnavailable, TargetChatAccessibilityProvider
from .attachments import MAX_CHAT_ATTACHMENTS_PER_MESSAGE, StagedChatAttachment
from .catalog import (
    ChatCatalogUnavailable,
    _header_value,
    _read_http_upgrade,
    _read_message,
    _send_frame,
)
from .plura_desktop import Target, TargetRuntime


CDP_HTTP_TIMEOUT_SECONDS = 2.0
CDP_COMMAND_TIMEOUT_SECONDS = 8.0
CDP_ATTACHMENT_TIMEOUT_SECONDS = 35.0
MAX_RENDERER_MESSAGES = 500
MAX_RENDERER_ITEMS = 1000
MAX_RENDERER_CHARACTERS = 6 * 1024 * 1024
MAX_RENDERER_ITEM_METADATA = 512
MAX_RENDERER_SEND_TEXT = 32 * 1024


class ChatRendererUnavailable(RuntimeError):
    pass


class TargetChatTranscriptProvider:
    """Prefer the canonical renderer contract and retain AX as a legacy fallback.

    Plura Desktop owns whether a target was launched with its loopback-only CDP
    endpoint. When that endpoint exists, Plura reads the same semantic
    DOM that the official Desktop renders instead of depending on a visible
    macOS window. Existing canonical sessions that predate renderer CDP continue
    to use the read-only Accessibility projection until their next normal quit
    and relaunch.
    """

    def __init__(
        self,
        runtime: TargetRuntime,
        catalog_provider: Callable[[Target], dict[str, Any]],
        *,
        renderer_extractor: Callable[[str, str, str, str], dict[str, Any]] | None = None,
        accessibility_provider: Callable[[Target, str], dict[str, Any]] | None = None,
    ) -> None:
        self.runtime = runtime
        self.catalog_provider = catalog_provider
        self.renderer_extractor = renderer_extractor or _extract_renderer_transcript
        self.accessibility_provider = accessibility_provider or TargetChatAccessibilityProvider(
            runtime,
            catalog_provider,
        )

    def __call__(self, target: Target, conversation_id: str) -> dict[str, Any]:
        snapshot = (
            self.catalog_provider.cached_snapshot(target)
            if hasattr(self.catalog_provider, "cached_snapshot")
            else None
        )
        if snapshot is not None:
            session, catalog = snapshot
        else:
            session = self.runtime.session(target)
            if session is None:
                raise ChatTranscriptUnavailable("target-not-ready")
            catalog = self.catalog_provider(target)
        if session.renderer_cdp_endpoint is None:
            return _with_semantic_items(self.accessibility_provider(target, conversation_id))
        entry, title, project_name = _cloud_chat_entry(catalog, conversation_id)

        try:
            parsed = self.renderer_extractor(
                session.renderer_cdp_endpoint,
                conversation_id,
                title,
                project_name or "",
            )
        except ChatRendererUnavailable as error:
            raise ChatTranscriptUnavailable(str(error)) from error
        return _with_semantic_items({
            "contractVersion": 1,
            "conversationId": conversation_id,
            "title": title,
            "projectId": entry.get("projectId"),
            "projectName": project_name,
            "source": "desktop-renderer",
            **parsed,
        })


class TargetChatComposerProvider:
    """Guarded write adapter for the already-authenticated official renderer.

    Writes deliberately have no Accessibility fallback. A target must expose
    its canonical loopback renderer CDP endpoint, the requested cloud
    conversation must still exist in the Desktop catalog, and the renderer
    transaction re-verifies the active conversation and empty composer before
    inserting or submitting any text.
    """

    def __init__(
        self,
        runtime: TargetRuntime,
        catalog_provider: Callable[[Target], dict[str, Any]],
        *,
        renderer_sender: Callable[
            [str, str, str, str, str, list[StagedChatAttachment]],
            dict[str, Any],
        ] | None = None,
    ) -> None:
        self.runtime = runtime
        self.catalog_provider = catalog_provider
        self.renderer_sender = renderer_sender or _send_renderer_message

    def __call__(
        self,
        target: Target,
        conversation_id: str,
        text: str,
        client_request_id: str,
        attachments: list[StagedChatAttachment] | None = None,
    ) -> dict[str, Any]:
        normalized_text = text.strip()
        normalized_attachments = list(attachments or [])
        if (
            (not normalized_text and not normalized_attachments)
            or len(normalized_text) > MAX_RENDERER_SEND_TEXT
            or len(normalized_attachments) > MAX_CHAT_ATTACHMENTS_PER_MESSAGE
        ):
            raise ChatTranscriptUnavailable("chat-message-invalid")
        session = self.runtime.session(target, refresh=True)
        if session is None:
            raise ChatTranscriptUnavailable("target-not-ready")
        if session.renderer_cdp_endpoint is None:
            raise ChatTranscriptUnavailable("desktop-renderer-unavailable")
        catalog = self.catalog_provider(target)
        entry, title, project_name = _cloud_chat_entry(catalog, conversation_id)
        try:
            result = self.renderer_sender(
                session.renderer_cdp_endpoint,
                conversation_id,
                title,
                project_name or "",
                normalized_text,
                normalized_attachments,
            )
        except ChatRendererUnavailable as error:
            raise ChatTranscriptUnavailable(str(error)) from error
        if result.get("status") != "submitted":
            reason = result.get("status")
            if not isinstance(reason, str) or not reason:
                reason = "desktop-renderer-failed"
            raise ChatTranscriptUnavailable(reason)
        return {
            "contractVersion": 1,
            "conversationId": conversation_id,
            "clientRequestId": client_request_id,
            "status": "submitted",
            "source": "desktop-renderer",
            "attachmentCount": len(normalized_attachments),
            "title": title,
            "projectId": entry.get("projectId"),
            "projectName": project_name,
        }


def _cloud_chat_entry(
    catalog: dict[str, Any],
    conversation_id: str,
) -> tuple[dict[str, Any], str, str | None]:
    entries = catalog.get("entries")
    if not isinstance(entries, list):
        raise ChatTranscriptUnavailable("desktop-catalog-unavailable")
    entry = next(
        (
            item
            for item in entries
            if isinstance(item, dict) and item.get("id") == conversation_id
        ),
        None,
    )
    if entry is None:
        raise ChatTranscriptUnavailable("conversation-not-in-catalog")
    if entry.get("sourceKind") != "chatgpt":
        raise ChatTranscriptUnavailable("conversation-is-local-thread")
    title = entry.get("title")
    if not isinstance(title, str) or not title.strip():
        raise ChatTranscriptUnavailable("conversation-title-unavailable")
    project_name = entry.get("projectName")
    if project_name is not None and not isinstance(project_name, str):
        project_name = None
    return entry, title, project_name


def _with_semantic_items(payload: dict[str, Any]) -> dict[str, Any]:
    """Add the forward-compatible semantic timeline without breaking v1 clients.

    The legacy `messages` projection remains authoritative for compatibility.
    Rich renderer cards can be added to `items` independently as they become
    safely recognizable; older clients will continue to ignore the new field.
    """
    raw_items = payload.get("items")
    if not isinstance(raw_items, list):
        messages = payload.get("messages")
        if not isinstance(messages, list):
            return payload
        raw_items = []
        for message in messages:
            if not isinstance(message, dict):
                continue
            role = message.get("role")
            text = message.get("text")
            if role not in {"user", "assistant"} or not isinstance(text, str):
                continue
            segments = message.get("segments")
            if not isinstance(segments, list) or not all(isinstance(value, str) for value in segments):
                segments = [text]
            raw_items.append({
                "kind": "message",
                "role": role,
                "text": text,
                "segments": segments,
            })
    capabilities = payload.get("capabilities")
    if not isinstance(capabilities, dict):
        capabilities = {
            "sendText": payload.get("source") == "desktop-renderer",
            "attachments": False,
        }
    return {
        **payload,
        "items": _normalize_semantic_items(raw_items),
        "capabilities": {
            "sendText": capabilities.get("sendText") is True,
            "attachments": capabilities.get("attachments") is True,
        },
    }


def _normalize_semantic_items(raw_items: list[Any]) -> list[dict[str, Any]]:
    if len(raw_items) > MAX_RENDERER_ITEMS:
        raise ChatRendererUnavailable("desktop-accessibility-output-too-large")

    normalized: list[dict[str, Any]] = []
    character_count = 0
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        kind = raw.get("kind")
        if not isinstance(kind, str) or not kind.strip():
            continue
        kind = kind.strip()[:64]
        text = raw.get("text")
        if not isinstance(text, str):
            text = ""
        character_count += len(text)
        if character_count > MAX_RENDERER_CHARACTERS:
            raise ChatRendererUnavailable("desktop-accessibility-output-too-large")

        item: dict[str, Any] = {"kind": kind, "text": text}
        role = raw.get("role")
        if role in {"user", "assistant", "activity"}:
            item["role"] = role
        segments = raw.get("segments")
        if isinstance(segments, list) and all(isinstance(value, str) for value in segments):
            item["segments"] = segments
        for key in ("sourceId", "title", "status"):
            value = raw.get(key)
            if isinstance(value, str) and value:
                item[key] = value[:MAX_RENDERER_ITEM_METADATA]
        duration_ms = raw.get("durationMs")
        if isinstance(duration_ms, int) and not isinstance(duration_ms, bool) and duration_ms >= 0:
            item["durationMs"] = duration_ms
        normalized.append(item)
    return normalized


class _CDPConnection:
    def __init__(self, websocket_url: str, origin: str) -> None:
        parsed = urlsplit(websocket_url)
        if (
            parsed.scheme != "ws"
            or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}
            or parsed.port is None
            or not parsed.path.startswith("/devtools/")
        ):
            raise ChatRendererUnavailable("desktop-renderer-unavailable")
        self._socket = socket.create_connection(
            (parsed.hostname, parsed.port),
            timeout=CDP_HTTP_TIMEOUT_SECONDS,
        )
        self._socket.settimeout(CDP_COMMAND_TIMEOUT_SECONDS)
        key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        host = f"[{parsed.hostname}]:{parsed.port}" if ":" in parsed.hostname else f"{parsed.hostname}:{parsed.port}"
        path = parsed.path + (f"?{parsed.query}" if parsed.query else "")
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Origin: {origin}\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        ).encode("ascii")
        self._socket.sendall(request)
        header, remainder = _read_http_upgrade(self._socket)
        if b" 101 " not in header.split(b"\r\n", 1)[0]:
            self.close()
            raise ChatRendererUnavailable("desktop-renderer-unavailable")
        expected = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        if _header_value(header, b"sec-websocket-accept") != expected:
            self.close()
            raise ChatRendererUnavailable("desktop-renderer-unavailable")
        self._buffered = bytearray(remainder)
        self._next_id = 1

    def close(self) -> None:
        sock = getattr(self, "_socket", None)
        if sock is not None:
            try:
                sock.close()
            finally:
                self._socket = None

    def set_timeout(self, seconds: float) -> None:
        if self._socket is None:
            raise ChatRendererUnavailable("desktop-renderer-unavailable")
        self._socket.settimeout(seconds)

    def call(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        request_id = self._next_id
        self._next_id += 1
        payload = json.dumps(
            {"id": request_id, "method": method, "params": params},
            separators=(",", ":"),
        ).encode("utf-8")
        _send_frame(self._socket, 0x1, payload)
        while True:
            opcode, raw = _read_message(self._socket, self._buffered)
            if opcode == 0x8:
                raise ChatRendererUnavailable("desktop-renderer-unavailable")
            if opcode != 0x1:
                continue
            message = json.loads(raw.decode("utf-8"))
            if message.get("id") != request_id:
                continue
            if isinstance(message.get("error"), dict):
                raise ChatRendererUnavailable("desktop-renderer-failed")
            result = message.get("result")
            if not isinstance(result, dict):
                raise ChatRendererUnavailable("desktop-renderer-failed")
            return result

    def evaluate(self, expression: str) -> Any:
        result = self.call(
            "Runtime.evaluate",
            {
                "expression": expression,
                "awaitPromise": True,
                "returnByValue": True,
                "userGesture": True,
            },
        )
        if result.get("exceptionDetails") is not None:
            raise ChatRendererUnavailable("desktop-renderer-failed")
        remote = result.get("result")
        if not isinstance(remote, dict) or "value" not in remote:
            raise ChatRendererUnavailable("desktop-renderer-failed")
        return remote["value"]

    def evaluate_object(self, expression: str) -> str:
        result = self.call(
            "Runtime.evaluate",
            {
                "expression": expression,
                "awaitPromise": True,
                "returnByValue": False,
                "userGesture": True,
            },
        )
        if result.get("exceptionDetails") is not None:
            raise ChatRendererUnavailable("desktop-renderer-failed")
        remote = result.get("result")
        if not isinstance(remote, dict) or remote.get("subtype") == "null":
            raise ChatRendererUnavailable("desktop-attachment-input-unavailable")
        object_id = remote.get("objectId")
        if not isinstance(object_id, str) or not object_id:
            raise ChatRendererUnavailable("desktop-attachment-input-unavailable")
        return object_id


def _renderer_targets(endpoint: str) -> tuple[str, list[dict[str, Any]]]:
    parsed = urlsplit(endpoint)
    if (
        parsed.scheme != "http"
        or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}
        or parsed.port is None
    ):
        raise ChatRendererUnavailable("desktop-renderer-unavailable")
    origin = f"http://127.0.0.1:{parsed.port}"
    connection = http.client.HTTPConnection(
        parsed.hostname,
        parsed.port,
        timeout=CDP_HTTP_TIMEOUT_SECONDS,
    )
    try:
        connection.request("GET", "/json/list")
        response = connection.getresponse()
        if response.status != 200:
            raise ChatRendererUnavailable("desktop-renderer-unavailable")
        body = response.read(2 * 1024 * 1024 + 1)
        if len(body) > 2 * 1024 * 1024:
            raise ChatRendererUnavailable("desktop-renderer-failed")
        value = json.loads(body.decode("utf-8"))
    finally:
        connection.close()
    if not isinstance(value, list):
        raise ChatRendererUnavailable("desktop-renderer-failed")
    targets = [item for item in value if isinstance(item, dict) and item.get("type") in {"page", "webview"}]
    if not targets:
        raise ChatRendererUnavailable("desktop-renderer-unavailable")
    return origin, targets


def _exact_chat_renderer_target(endpoint: str) -> tuple[str, dict[str, Any]]:
    origin, targets = _renderer_targets(endpoint)
    matches = [
        target
        for target in targets
        if target.get("type") == "page"
        and isinstance(target.get("url"), str)
        and target["url"].startswith("app://-/index.html")
        and "initialRoute=" not in target["url"]
        and isinstance(target.get("webSocketDebuggerUrl"), str)
        and target.get("webSocketDebuggerUrl")
    ]
    if len(matches) != 1:
        raise ChatRendererUnavailable(
            "desktop-renderer-ambiguous" if len(matches) > 1 else "desktop-renderer-unavailable"
        )
    return origin, matches[0]


def _send_renderer_message(
    endpoint: str,
    conversation_id: str,
    title: str,
    project_name: str,
    text: str,
    attachments: list[StagedChatAttachment],
) -> dict[str, Any]:
    origin, target = _exact_chat_renderer_target(endpoint)
    websocket_url = target.get("webSocketDebuggerUrl")
    if not isinstance(websocket_url, str) or not websocket_url:
        raise ChatRendererUnavailable("desktop-renderer-unavailable")
    connection: _CDPConnection | None = None
    submit_attempted = False
    file_input_object_id: str | None = None
    filenames = [attachment.filename for attachment in attachments]
    mime_types = [attachment.mime_type for attachment in attachments]
    try:
        connection = _CDPConnection(websocket_url, origin)
        prepared = connection.evaluate(
            _composer_focus_expression(
                conversation_id,
                title,
                project_name,
                filenames,
                mime_types,
            )
        )
        if not isinstance(prepared, dict):
            raise ChatRendererUnavailable("desktop-renderer-failed")
        status = prepared.get("status")
        if status != "ready":
            if isinstance(status, str) and status:
                raise ChatRendererUnavailable(status)
            raise ChatRendererUnavailable("desktop-renderer-failed")
        user_message_count = prepared.get("userMessageCount")
        if not isinstance(user_message_count, int) or isinstance(user_message_count, bool) or user_message_count < 0:
            raise ChatRendererUnavailable("desktop-renderer-failed")

        if attachments:
            file_input_object_id = connection.evaluate_object(
                _attachment_input_expression(filenames, mime_types)
            )
            connection.call(
                "DOM.setFileInputFiles",
                {
                    "files": [str(attachment.path) for attachment in attachments],
                    "objectId": file_input_object_id,
                },
            )
            attached = connection.evaluate(_attachment_ready_expression(filenames, mime_types))
            if not isinstance(attached, dict) or attached.get("status") != "ready":
                status = attached.get("status") if isinstance(attached, dict) else None
                raise ChatRendererUnavailable(
                    status if isinstance(status, str) and status else "desktop-attachment-changed"
                )

        if text:
            connection.call("Input.insertText", {"text": text})
        if attachments:
            connection.set_timeout(CDP_ATTACHMENT_TIMEOUT_SECONDS)
        submit_attempted = True
        submitted = connection.evaluate(
            _composer_submit_expression(
                conversation_id,
                text,
                user_message_count,
                filenames,
            )
        )
        if not isinstance(submitted, dict):
            raise ChatRendererUnavailable("chat-send-uncertain")
        status = submitted.get("status")
        if status == "submitted":
            return submitted
        if isinstance(status, str) and status:
            raise ChatRendererUnavailable(status)
        raise ChatRendererUnavailable("chat-send-uncertain")
    except ChatRendererUnavailable:
        raise
    except (OSError, TimeoutError, socket.timeout, json.JSONDecodeError) as error:
        # Once the submit transaction begins, a transport failure may have
        # happened after Desktop accepted it. Never convert that into an
        # auto-retryable generic renderer error.
        reason = "chat-send-uncertain" if submit_attempted else "desktop-renderer-unavailable"
        raise ChatRendererUnavailable(reason) from error
    finally:
        if connection is not None:
            if file_input_object_id is not None:
                try:
                    connection.call("Runtime.releaseObject", {"objectId": file_input_object_id})
                except (ChatRendererUnavailable, OSError, TimeoutError, socket.timeout, json.JSONDecodeError):
                    pass
            connection.close()


def _attachment_selector_javascript() -> str:
    return r"""
  const attachmentAcceptTokens = candidate => (candidate.getAttribute('accept') || '')
    .split(',').map(value => value.trim().toLowerCase()).filter(Boolean);
  const attachmentAcceptsFile = (candidate, name, mime) => {
    const tokens = attachmentAcceptTokens(candidate);
    if (tokens.length === 0) return true;
    const loweredName = name.toLowerCase();
    const loweredMime = mime.toLowerCase();
    return tokens.some(value => {
      if (value.startsWith('.')) return loweredName.endsWith(value);
      if (value.endsWith('/*')) return loweredMime.startsWith(value.slice(0, -1));
      return loweredMime === value;
    });
  };
  const selectAttachmentInput = () => {
    const candidates = Array.from(document.querySelectorAll('input[type="file"]'))
      .filter(candidate => !candidate.disabled)
      .filter(candidate => attachmentNames.every((name, index) =>
        attachmentAcceptsFile(candidate, name, attachmentMimeTypes[index] || 'application/octet-stream')
      ))
      .filter(candidate => candidate.multiple || attachmentNames.length === 1);
    if (candidates.length === 0) {
      return {status: 'desktop-attachment-input-unavailable', element: null};
    }
    // Prefer a generic file input over media-specific duplicates. ChatGPT
    // currently exposes several sibling file inputs (photos/videos, photos,
    // files); the generic input preserves file semantics without depending on
    // localized aria-label text. If the generic shape ever becomes ambiguous,
    // fail closed rather than guessing.
    const ranked = candidates.map(element => {
      const tokens = attachmentAcceptTokens(element);
      return {element, score: tokens.length === 0 ? 10000 : 100 + tokens.length};
    });
    const bestScore = Math.max(...ranked.map(item => item.score));
    const best = ranked.filter(item => item.score === bestScore);
    if (best.length !== 1) {
      return {status: 'desktop-attachment-input-ambiguous', element: null};
    }
    return {status: 'ok', element: best[0].element};
  };
"""


def _composer_focus_expression(
    conversation_id: str,
    title: str,
    project_name: str,
    attachment_names: list[str] | None = None,
    attachment_mime_types: list[str] | None = None,
) -> str:
    conversation_json = json.dumps(conversation_id)
    title_json = json.dumps(title)
    project_json = json.dumps(project_name)
    attachment_names_json = json.dumps(attachment_names or [])
    attachment_mime_types_json = json.dumps(attachment_mime_types or [])
    attachment_selector_js = _attachment_selector_javascript()
    return f"""
(async () => {{
  const conversationId = {conversation_json};
  const expectedTitle = {title_json};
  const projectName = {project_json};
  const attachmentNames = {attachment_names_json};
  const attachmentMimeTypes = {attachment_mime_types_json};
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const clean = value => (value || '').replace(/\\s+/g, ' ').trim();
  const matchesTitle = value => {{
    const candidate = clean(value);
    const target = clean(expectedTitle);
    if (!candidate || !target) return false;
    if (candidate === target) return true;
    if (candidate.endsWith('…') && target.startsWith(candidate.slice(0, -1))) return true;
    if (target.endsWith('…') && candidate.startsWith(target.slice(0, -1))) return true;
    return false;
  }};
  const label = element => clean(
    element?.getAttribute?.('aria-label') ||
    element?.getAttribute?.('title') ||
    element?.innerText ||
    element?.textContent || ''
  );
  const candidates = root => Array.from(
    (root || document).querySelectorAll('a[href], button, [role="button"]')
  );
  const rowFor = root => {{
    const items = candidates(root);
    const byId = items.filter(element => (element.getAttribute('href') || '').includes(conversationId));
    if (byId.length === 1) return byId[0];
    const byTitle = items.filter(element => matchesTitle(label(element)));
    return byTitle.length === 1 ? byTitle[0] : null;
  }};
  let scope = document;
  if (projectName) {{
    const listLabel = `Chats in ${{projectName}}`;
    const projectList = () => Array.from(document.querySelectorAll('[aria-label]'))
      .find(element => clean(element.getAttribute('aria-label')) === listLabel) || null;
    scope = projectList();
    if (!scope) {{
      const projectButtons = candidates(document).filter(element => clean(label(element)) === clean(projectName));
      if (projectButtons.length === 1) {{
        projectButtons[0].scrollIntoView({{block: 'nearest'}});
        projectButtons[0].click();
        for (let i = 0; i < 20 && !scope; i += 1) {{
          await sleep(50);
          scope = projectList();
        }}
      }}
    }}
    if (!scope) return {{status: 'conversation-row-unavailable'}};
  }}
  const row = rowFor(scope);
  if (!row) return {{status: 'conversation-row-unavailable'}};
  const isCurrent = () => {{
    if (location.href.includes(conversationId)) return true;
    if (matchesTitle(document.title)) return true;
    return rowFor(document)?.getAttribute('aria-current') === 'page';
  }};
  if (!isCurrent()) {{
    row.scrollIntoView({{block: 'nearest'}});
    row.click();
    let selected = false;
    for (let i = 0; i < 60; i += 1) {{
      await sleep(50);
      if (isCurrent()) {{ selected = true; break; }}
    }}
    if (!selected) return {{status: 'conversation-row-not-actionable'}};
  }}
  const visible = element => !!element && element.getClientRects().length > 0 && !element.disabled;
  const composer = () => {{
    const selectors = [
      '#prompt-textarea',
      '[data-testid="composer-input"]',
      'textarea',
      '[contenteditable="true"][role="textbox"]',
      '[contenteditable="true"]'
    ];
    for (const selector of selectors) {{
      const matches = Array.from(document.querySelectorAll(selector)).filter(visible);
      if (matches.length === 1) return matches[0];
    }}
    return null;
  }};
  let input = composer();
  for (let i = 0; i < 40 && !input; i += 1) {{
    await sleep(50);
    input = composer();
  }}
  if (!input) return {{status: 'desktop-composer-unavailable'}};
  const value = 'value' in input ? input.value : (input.innerText || input.textContent || '');
  if (value.trim()) return {{status: 'desktop-composer-draft-present'}};
  if (input.getAttribute('contenteditable') === 'false' || input.disabled) {{
    return {{status: 'desktop-conversation-busy'}};
  }}
{attachment_selector_js}
  if (attachmentNames.length) {{
    if (Array.from(document.querySelectorAll('input[type="file"]'))
      .some(candidate => (candidate.files?.length || 0) > 0)) {{
      return {{status: 'desktop-attachment-draft-present'}};
    }}
    const uploadInput = selectAttachmentInput();
    if (uploadInput.status !== 'ok') return {{status: uploadInput.status}};
  }}
  input.focus();
  if (document.activeElement !== input && !input.contains(document.activeElement)) {{
    return {{status: 'desktop-composer-unavailable'}};
  }}
  return {{
    status: 'ready',
    userMessageCount: document.querySelectorAll('[data-turn-key] [data-user-message-bubble]').length
  }};
}})()
"""


def _attachment_input_expression(attachment_names: list[str], attachment_mime_types: list[str]) -> str:
    names_json = json.dumps(attachment_names)
    mime_types_json = json.dumps(attachment_mime_types)
    selector_js = _attachment_selector_javascript()
    return f"""
(() => {{
  const attachmentNames = {names_json};
  const attachmentMimeTypes = {mime_types_json};
{selector_js}
  const selection = selectAttachmentInput();
  return selection.status === 'ok' ? selection.element : null;
}})()
"""


def _attachment_ready_expression(attachment_names: list[str], attachment_mime_types: list[str]) -> str:
    names_json = json.dumps(attachment_names)
    mime_types_json = json.dumps(attachment_mime_types)
    selector_js = _attachment_selector_javascript()
    return f"""
(() => {{
  const attachmentNames = {names_json};
  const attachmentMimeTypes = {mime_types_json};
{selector_js}
  const selection = selectAttachmentInput();
  if (selection.status !== 'ok') return {{status: selection.status}};
  const observed = Array.from(selection.element.files || []).map(file => file.name).sort();
  const expected = attachmentNames.slice().sort();
  if (observed.length !== expected.length || observed.some((name, index) => name !== expected[index])) {{
    return {{status: 'desktop-attachment-changed'}};
  }}
  return {{status: 'ready'}};
}})()
"""


def _composer_submit_expression(
    conversation_id: str,
    text: str,
    previous_user_message_count: int,
    attachment_names: list[str] | None = None,
) -> str:
    conversation_json = json.dumps(conversation_id)
    text_json = json.dumps(text)
    attachment_names_json = json.dumps(attachment_names or [])
    return f"""
(async () => {{
  const conversationId = {conversation_json};
  const expectedText = {text_json};
  const previousUserMessageCount = {previous_user_message_count};
  const attachmentNames = {attachment_names_json};
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const normalize = value => (value || '').replace(/\\r\\n/g, '\\n').trim();
  const visible = element => !!element && element.getClientRects().length > 0;
  const composer = () => {{
    const selectors = [
      '#prompt-textarea',
      '[data-testid="composer-input"]',
      'textarea',
      '[contenteditable="true"][role="textbox"]',
      '[contenteditable="true"]'
    ];
    for (const selector of selectors) {{
      const matches = Array.from(document.querySelectorAll(selector)).filter(visible);
      if (matches.length === 1) return matches[0];
    }}
    return null;
  }};
  if (!location.href.includes(conversationId)) return {{status: 'conversation-changed-before-submit'}};
  const input = composer();
  if (!input) return {{status: 'desktop-composer-unavailable'}};
  const value = 'value' in input ? input.value : (input.innerText || input.textContent || '');
  if (normalize(value) !== normalize(expectedText)) return {{status: 'desktop-composer-changed'}};

  if (attachmentNames.length) {{
    const observed = Array.from(document.querySelectorAll('input[type="file"]'))
      .flatMap(candidate => Array.from(candidate.files || []))
      .map(file => file.name)
      .sort();
    const expected = attachmentNames.slice().sort();
    if (observed.length !== expected.length || observed.some((name, index) => name !== expected[index])) {{
      return {{status: 'desktop-attachment-changed'}};
    }}
  }}

  const form = input.closest('form');
  const roots = [form, input.parentElement, document].filter(Boolean);
  const findSend = () => {{
    for (const root of roots) {{
      const semantic = Array.from(root.querySelectorAll(
        'button[type="submit"],button[data-testid*="send" i],[role="button"][data-testid*="send" i]'
      )).filter(visible);
      if (semantic.length === 1) return semantic[0];
    }}
    const fallbackLabels = new Set(['Send', 'Send prompt', 'Submit']);
    const labelled = Array.from(document.querySelectorAll('button,[role="button"]'))
      .filter(visible)
      .filter(element => fallbackLabels.has(normalize(
        element.getAttribute('aria-label') || element.getAttribute('title') || element.textContent || ''
      )));
    return labelled.length === 1 ? labelled[0] : null;
  }};
  let send = findSend();
  const waitIterations = attachmentNames.length ? 300 : 1;
  for (let i = 0; i < waitIterations && (!send || send.disabled); i += 1) {{
    await sleep(100);
    if (!location.href.includes(conversationId)) return {{status: 'conversation-changed-before-submit'}};
    send = findSend();
  }}
  if (!send || send.disabled) {{
    return {{status: attachmentNames.length ? 'desktop-attachment-upload-timeout' : 'desktop-composer-send-unavailable'}};
  }}
  send.click();

  const clean = value => (value || '').replace(/\\s+/g, ' ').trim();
  const expectedDisplay = clean(expectedText);
  for (let i = 0; i < 60; i += 1) {{
    await sleep(50);
    if (!location.href.includes(conversationId)) return {{status: 'chat-send-uncertain'}};
    const bubbles = Array.from(document.querySelectorAll('[data-turn-key] [data-user-message-bubble]'));
    if (bubbles.length > previousUserMessageCount) {{
      const latest = bubbles[bubbles.length - 1];
      const latestText = clean(latest.innerText || latest.textContent || '');
      if (!expectedDisplay || latestText === expectedDisplay || latestText.includes(expectedDisplay)) {{
        return {{status: 'submitted', userMessageCount: bubbles.length}};
      }}
      return {{status: 'chat-send-uncertain'}};
    }}
  }}
  return {{status: 'chat-send-uncertain'}};
}})()
"""


def _normalize_renderer_transcript_result(value: dict[str, Any]) -> dict[str, Any]:
    """Validate one renderer snapshot and preserve only a complete semantic timeline.

    The legacy message projection remains the compatibility baseline. Renderer
    semantic items are forwarded only when their message items reproduce that
    baseline in the same order, so a partial/new adapter cannot accidentally
    hide user or assistant messages on clients that prefer the rich timeline.
    """
    messages = value.get("messages")
    if not isinstance(messages, list) or not messages:
        raise ChatRendererUnavailable("desktop-transcript-unavailable")
    if len(messages) > MAX_RENDERER_MESSAGES:
        raise ChatRendererUnavailable("desktop-accessibility-output-too-large")

    normalized: list[dict[str, Any]] = []
    character_count = 0
    for item in messages:
        if not isinstance(item, dict) or item.get("role") not in {"user", "assistant"}:
            raise ChatRendererUnavailable("desktop-renderer-failed")
        text = item.get("text")
        if not isinstance(text, str) or not text.strip():
            continue
        text = text.strip()
        character_count += len(text)
        if character_count > MAX_RENDERER_CHARACTERS:
            raise ChatRendererUnavailable("desktop-accessibility-output-too-large")
        normalized.append({"role": item["role"], "text": text, "segments": [text]})
    if not normalized:
        raise ChatRendererUnavailable("desktop-transcript-unavailable")

    result: dict[str, Any] = {
        "messages": normalized,
        "activity": "streaming" if value.get("activity") == "streaming" else "idle",
        "isPartial": value.get("isPartial") is True,
        "messageCount": len(normalized),
        "capabilities": {
            "sendText": True,
            "attachments": value.get("attachmentCapable") is True,
        },
    }

    raw_items = value.get("items")
    if isinstance(raw_items, list):
        semantic_items = _normalize_semantic_items(raw_items)
        message_projection = [(item["role"], item["text"]) for item in normalized]
        timeline_projection = [
            (item.get("role"), item["text"].strip())
            for item in semantic_items
            if item.get("kind") == "message"
            and item.get("role") in {"user", "assistant"}
            and item["text"].strip()
        ]
        if timeline_projection == message_projection:
            result["items"] = semantic_items

    return result


def _extract_renderer_transcript(
    endpoint: str,
    conversation_id: str,
    title: str,
    project_name: str,
) -> dict[str, Any]:
    origin, targets = _renderer_targets(endpoint)
    chat_targets = [
        target
        for target in targets
        if target.get("type") == "page"
        and isinstance(target.get("url"), str)
        and target["url"].startswith("app://-/index.html")
        and "initialRoute=" not in target["url"]
    ]
    if chat_targets:
        targets = chat_targets
    else:
        targets = sorted(targets, key=lambda item: item.get("type") != "page")
    expression = _transcript_expression(conversation_id, title, project_name)
    last_reason = "conversation-row-unavailable"
    for target in targets:
        websocket_url = target.get("webSocketDebuggerUrl")
        if not isinstance(websocket_url, str) or not websocket_url:
            continue
        connection: _CDPConnection | None = None
        try:
            connection = _CDPConnection(websocket_url, origin)
            value = connection.evaluate(expression)
            if not isinstance(value, dict):
                last_reason = "desktop-renderer-failed"
                continue
            status = value.get("status")
            if status != "ok":
                if isinstance(status, str) and status in {
                    "conversation-row-unavailable",
                    "conversation-row-not-actionable",
                    "desktop-transcript-unavailable",
                    "desktop-accessibility-output-too-large",
                }:
                    last_reason = status
                continue
            return _normalize_renderer_transcript_result(value)
        except (ChatCatalogUnavailable, ChatRendererUnavailable, OSError, TimeoutError, json.JSONDecodeError) as error:
            if isinstance(error, ChatRendererUnavailable):
                last_reason = str(error) or "desktop-renderer-failed"
            elif isinstance(error, (socket.timeout, TimeoutError)):
                last_reason = "desktop-renderer-timeout"
            else:
                last_reason = "desktop-renderer-unavailable"
        finally:
            if connection is not None:
                connection.close()
    raise ChatRendererUnavailable(last_reason)

def _semantic_markdown_javascript() -> str:
    """Renderer-side semantic HTML -> conservative Markdown projection.

    The projection intentionally depends on standard HTML semantics and stable
    data/ARIA relationships rather than ChatGPT CSS class names. Unknown
    containers recurse through their children and ultimately retain visible
    text, so a markup change degrades formatting before it loses content.
    """
    return r"""
  const ignoredContentSelector = 'button,[role="button"],input,textarea,select,nav,aside,script,style,[aria-hidden="true"]';
  const collapseInline = value => (value || '').replace(/[\t\f\v ]+/g, ' ').replace(/ *\n */g, '\n').trim();
  const safeHref = element => {
    const value = element?.getAttribute?.('href') || '';
    try {
      const url = new URL(value, location.href);
      return (url.protocol === 'http:' || url.protocol === 'https:') ? url.href : '';
    } catch (_) {
      return '';
    }
  };
  const inlineMarkdown = node => {
    if (!node) return '';
    if (node.nodeType === Node.TEXT_NODE) return node.nodeValue || '';
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    const element = node;
    if (element.matches?.(ignoredContentSelector)) return '';
    const tag = element.tagName.toLowerCase();
    if (tag === 'br') return '\n';
    if (tag === 'img') {
      const src = element.currentSrc || element.getAttribute('src') || '';
      const alt = collapseInline(element.getAttribute('alt') || 'Image').replace(/\]/g, '\\]');
      if (/^https:\/\//i.test(src)) return `![${alt}](${src})`;
      return alt ? `[${alt}]` : '';
    }
    const childText = Array.from(element.childNodes).map(inlineMarkdown).join('');
    const normalized = collapseInline(childText);
    if (!normalized) return '';
    if (tag === 'strong' || tag === 'b') return `**${normalized}**`;
    if (tag === 'em' || tag === 'i') return `*${normalized}*`;
    if (tag === 'code' && element.parentElement?.tagName?.toLowerCase() !== 'pre') {
      const fence = normalized.includes('`') ? '``' : '`';
      return `${fence}${normalized}${fence}`;
    }
    if (tag === 'a') {
      const href = safeHref(element);
      return href ? `[${normalized}](${href})` : normalized;
    }
    return childText;
  };
  const codeLanguage = element => {
    const candidates = [
      element?.getAttribute?.('data-language'),
      element?.querySelector?.('code')?.getAttribute?.('data-language'),
      element?.querySelector?.('code')?.className,
      element?.className,
    ].filter(value => typeof value === 'string');
    for (const candidate of candidates) {
      const match = candidate.match(/(?:language-|lang-)?([A-Za-z0-9_+#.-]{1,32})/);
      if (match) return match[1];
    }
    return '';
  };
  const fencedCode = element => {
    const code = (element.querySelector?.('code')?.textContent ?? element.textContent ?? '').replace(/\n$/, '');
    if (!code.trim()) return '';
    const runs = code.match(/`+/g) || [];
    const longest = runs.reduce((value, run) => Math.max(value, run.length), 0);
    const fence = '`'.repeat(Math.max(3, longest + 1));
    const language = codeLanguage(element);
    return `${fence}${language ? language : ''}\n${code}\n${fence}`;
  };
  const blockMarkdown = (node, depth = 0) => {
    if (!node) return '';
    if (node.nodeType === Node.TEXT_NODE) return collapseInline(node.nodeValue || '');
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    const element = node;
    if (element.matches?.(ignoredContentSelector)) return '';
    const tag = element.tagName.toLowerCase();
    if (/^h[1-6]$/.test(tag)) {
      const level = Number(tag.slice(1));
      const text = collapseInline(Array.from(element.childNodes).map(inlineMarkdown).join(''));
      return text ? `${'#'.repeat(level)} ${text}` : '';
    }
    if (tag === 'pre') return fencedCode(element);
    if (tag === 'blockquote') {
      const content = Array.from(element.childNodes).map(child => blockMarkdown(child, depth + 1)).filter(Boolean).join('\n\n');
      return content ? content.split('\n').map(line => `> ${line}`).join('\n') : '';
    }
    if (tag === 'ul' || tag === 'ol') {
      const ordered = tag === 'ol';
      let ordinal = Number(element.getAttribute('start') || '1');
      const lines = [];
      for (const child of Array.from(element.children).filter(child => child.tagName?.toLowerCase() === 'li')) {
        const nested = Array.from(child.children).filter(candidate => ['ul', 'ol'].includes(candidate.tagName?.toLowerCase()));
        const clone = child.cloneNode(true);
        clone.querySelectorAll(':scope > ul,:scope > ol').forEach(candidate => candidate.remove());
        const content = collapseInline(Array.from(clone.childNodes).map(inlineMarkdown).join(''));
        const marker = ordered ? `${ordinal}.` : '-';
        if (content) lines.push(`${'  '.repeat(depth)}${marker} ${content}`);
        for (const nestedList of nested) {
          const nestedText = blockMarkdown(nestedList, depth + 1);
          if (nestedText) lines.push(nestedText);
        }
        ordinal += 1;
      }
      return lines.join('\n');
    }
    if (tag === 'hr') return '---';
    if (tag === 'table') {
      const rows = Array.from(element.querySelectorAll('tr')).map(row =>
        Array.from(row.querySelectorAll(':scope > th,:scope > td')).map(cell => collapseInline(cell.innerText || cell.textContent || ''))
      ).filter(row => row.length > 0);
      if (!rows.length) return '';
      const width = Math.max(...rows.map(row => row.length));
      const normalizedRows = rows.map(row => Array.from({length: width}, (_, index) => (row[index] || '').replace(/\|/g, '\\|')));
      const header = normalizedRows[0];
      const body = normalizedRows.slice(1);
      return [
        `| ${header.join(' | ')} |`,
        `| ${header.map(() => '---').join(' | ')} |`,
        ...body.map(row => `| ${row.join(' | ')} |`),
      ].join('\n');
    }
    if (['p', 'figcaption'].includes(tag)) {
      return collapseInline(Array.from(element.childNodes).map(inlineMarkdown).join(''));
    }
    if (['code', 'a', 'strong', 'b', 'em', 'i', 'span'].includes(tag)) {
      return collapseInline(inlineMarkdown(element));
    }
    const children = Array.from(element.childNodes).map(child => blockMarkdown(child, depth)).filter(Boolean);
    if (children.length) return children.join('\n\n');
    return collapseInline(element.innerText || element.textContent || '');
  };
  const semanticMarkdown = element => {
    if (!element) return '';
    const clone = element.cloneNode(true);
    clone.querySelectorAll(ignoredContentSelector).forEach(candidate => candidate.remove());
    clone.querySelectorAll('[data-conversation-role="assistant"]').forEach(candidate => candidate.remove());
    const value = blockMarkdown(clone);
    return value.replace(/\n{3,}/g, '\n\n').trim();
  };
"""


def _transcript_expression(conversation_id: str, title: str, project_name: str) -> str:
    conversation_json = json.dumps(conversation_id)
    title_json = json.dumps(title)
    project_json = json.dumps(project_name)
    semantic_markdown_js = _semantic_markdown_javascript()
    return f"""
(async () => {{
  const conversationId = {conversation_json};
  const expectedTitle = {title_json};
  const projectName = {project_json};
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const clean = value => (value || '').replace(/\\s+/g, ' ').trim();
  const matchesTitle = value => {{
    const candidate = clean(value);
    const target = clean(expectedTitle);
    if (!candidate || !target) return false;
    if (candidate === target) return true;
    if (candidate.endsWith('…') && target.startsWith(candidate.slice(0, -1))) return true;
    if (target.endsWith('…') && candidate.startsWith(target.slice(0, -1))) return true;
    return false;
  }};
  const label = element => clean(
    element?.getAttribute?.('aria-label') ||
    element?.getAttribute?.('title') ||
    element?.innerText ||
    element?.textContent || ''
  );
  const candidates = root => Array.from(
    (root || document).querySelectorAll('a[href], button, [role="button"]')
  );
{semantic_markdown_js}
  const rowFor = root => {{
    const items = candidates(root);
    const byId = items.filter(element => (element.getAttribute('href') || '').includes(conversationId));
    if (byId.length === 1) return byId[0];
    const byTitle = items.filter(element => matchesTitle(label(element)));
    return byTitle.length === 1 ? byTitle[0] : null;
  }};
  let scope = document;
  if (projectName) {{
    const listLabel = `Chats in ${{projectName}}`;
    const projectList = () => Array.from(document.querySelectorAll('[aria-label]'))
      .find(element => clean(element.getAttribute('aria-label')) === listLabel) || null;
    scope = projectList();
    if (!scope) {{
      const projectButtons = candidates(document).filter(element => clean(label(element)) === clean(projectName));
      if (projectButtons.length === 1) {{
        projectButtons[0].scrollIntoView({{block: 'nearest'}});
        projectButtons[0].click();
        for (let i = 0; i < 20 && !scope; i += 1) {{
          await sleep(50);
          scope = projectList();
        }}
      }}
    }}
    if (!scope) return {{status: 'conversation-row-unavailable'}};
  }}
  let row = rowFor(scope);
  if (!row) return {{status: 'conversation-row-unavailable'}};
  const isCurrent = () => {{
    if (matchesTitle(document.title)) return true;
    const current = rowFor(document);
    if (current?.getAttribute('aria-current') === 'page') return true;
    return location.href.includes(conversationId);
  }};
  if (!isCurrent()) {{
    row.scrollIntoView({{block: 'nearest'}});
    row.click();
    let selected = false;
    for (let i = 0; i < 60; i += 1) {{
      await sleep(50);
      if (isCurrent()) {{ selected = true; break; }}
    }}
    if (!selected) return {{status: 'conversation-row-not-actionable'}};
  }}
  const stripRenderedText = element => {{
    if (!element) return '';
    const clone = element.cloneNode(true);
    clone.querySelectorAll('button,[role="button"],input,textarea,select,nav,aside,script,style,[aria-hidden="true"]')
      .forEach(candidate => candidate.remove());
    clone.querySelectorAll('[data-conversation-role="assistant"]').forEach(candidate => candidate.remove());
    return clean(clone.innerText || clone.textContent || '');
  }};
  // These hooks are emitted by the official Desktop renderer for semantic
  // activity surfaces. Keep them isolated here so DOM drift degrades to the
  // legacy message-only projection instead of guessing from localized text.
  const semanticActivityDefinitions = [
    {{selector: '[data-mcp-app-card]', kind: 'toolCall', title: 'App'}},
    {{selector: '[data-appshot-attachment]', kind: 'attachment', title: 'Screenshot'}},
    {{selector: '[data-codex-approval-surface]', kind: 'approval', title: 'Approval'}},
    {{selector: '[data-request-input-activity-root]', kind: 'notice', title: 'Input requested'}},
  ];
  const semanticActivities = turn => {{
    const candidates = [];
    for (const definition of semanticActivityDefinitions) {{
      for (const node of turn.querySelectorAll(definition.selector)) {{
        candidates.push({{node, definition}});
      }}
    }}
    candidates.sort((left, right) => {{
      if (left.node === right.node) return 0;
      const position = left.node.compareDocumentPosition(right.node);
      return position & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1;
    }});
    // Prefer the more specific nested surface when semantic roots overlap.
    // This prevents a tool/app wrapper from duplicating an embedded approval.
    return candidates.filter(candidate => !candidates.some(other =>
      other.node !== candidate.node && candidate.node.contains(other.node)
    )).map(({{node, definition}}) => {{
      const rendered = semanticMarkdown(node) || stripRenderedText(node);
      return {{
        kind: definition.kind,
        role: 'activity',
        title: definition.title,
        text: rendered.slice(0, 8000),
      }};
    }});
  }};
  const semanticProjection = () => {{
    const messages = [];
    const items = [];
    const turns = Array.from(document.querySelectorAll('[data-turn-key]'));
    for (const turn of turns) {{
      const userBubble = turn.querySelector('[data-user-message-bubble]');
      const userText = semanticMarkdown(userBubble) || stripRenderedText(userBubble);
      if (userText) {{
        messages.push({{role: 'user', text: userText}});
        items.push({{kind: 'message', role: 'user', text: userText, segments: [userText]}});
      }}

      items.push(...semanticActivities(turn));

      const assistantMarker = turn.querySelector('[data-conversation-role="assistant"]');
      const assistantUnit = assistantMarker?.closest?.('[data-content-search-unit-key]') || assistantMarker?.parentElement;
      const assistantText = semanticMarkdown(assistantUnit) || stripRenderedText(assistantUnit);
      if (assistantText) {{
        messages.push({{role: 'assistant', text: assistantText}});
        items.push({{kind: 'message', role: 'assistant', text: assistantText, segments: [assistantText]}});
      }}
    }}
    return {{messages, items}};
  }};
  const roleForMarker = marker => {{
    if (marker.getAttribute('data-conversation-role') === 'assistant') return 'assistant';
    const text = clean(marker.textContent);
    if (text === 'You said:') return 'user';
    if (text === 'ChatGPT said:') return 'assistant';
    return null;
  }};
  const markers = () => Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6,[data-conversation-role]'))
    .filter(marker => roleForMarker(marker) !== null);
  let projection = semanticProjection();
  let semantic = projection.messages;
  let messageMarkers = markers();
  for (let i = 0; i < 80 && semantic.length === 0 && messageMarkers.length === 0; i += 1) {{
    await sleep(50);
    projection = semanticProjection();
    semantic = projection.messages;
    messageMarkers = markers();
  }}
  const semanticIsComplete = semantic.length > 0 && (
    messageMarkers.length === 0 || semantic.length >= messageMarkers.length
  );
  let messages = semanticIsComplete ? semantic : [];
  const items = semanticIsComplete ? projection.items : null;
  let extractionStrategy = semanticIsComplete ? 'semantic-turn-markdown-v2' : 'marker-range-v2';
  if (messages.length === 0) {{
    if (messageMarkers.length === 0) return {{status: 'desktop-transcript-unavailable'}};
    const seen = new Set();
    messages = [];
    for (const marker of messageMarkers) {{
      const role = roleForMarker(marker);
      const container = marker.closest('[data-turn-key]') || marker.parentElement;
      if (!container) continue;
      const key = container.getAttribute?.('data-turn-key') || `${{role}}:${{messages.length}}`;
      const dedupeKey = `${{role}}:${{key}}`;
      if (seen.has(dedupeKey)) continue;
      seen.add(dedupeKey);
      const markersInContainer = messageMarkers.filter(candidate => candidate.closest('[data-turn-key]') === container);
      const markerIndex = markersInContainer.indexOf(marker);
      const range = document.createRange();
      range.setStartAfter(marker);
      if (markerIndex >= 0 && markerIndex + 1 < markersInContainer.length) {{
        range.setEndBefore(markersInContainer[markerIndex + 1]);
      }} else {{
        range.setEnd(container, container.childNodes.length);
      }}
      const clone = document.createElement('div');
      clone.appendChild(range.cloneContents());
      clone.querySelectorAll('button,[role="button"],input,textarea,select,nav,aside,script,style,[aria-hidden="true"]')
        .forEach(element => element.remove());
      clone.querySelectorAll('h1,h2,h3,h4,h5,h6,[data-conversation-role]').forEach(element => {{
        const text = clean(element.textContent);
        if (text === 'You said:' || text === 'ChatGPT said:' || element.getAttribute('data-conversation-role') === 'assistant') {{
          element.remove();
        }}
      }});
      const text = semanticMarkdown(clone) || clean(clone.innerText || clone.textContent || '');
      if (text) messages.push({{role, text}});
    }}
  }}
  if (messages.length === 0) return {{status: 'desktop-transcript-unavailable'}};
  const bodyText = clean(document.body?.innerText || '');
  const semanticStop = Array.from(document.querySelectorAll(
    '[data-testid*="stop" i],[data-testid*="interrupt" i],[aria-busy="true"]'
  )).some(element => element.getAttribute('aria-hidden') !== 'true');
  const stopLabels = new Set(['Stop generating', 'Stop response', 'Stop', 'Interrupt', 'Cancel response']);
  const streaming = semanticStop || candidates(document).some(element => stopLabels.has(label(element)));
  const attachmentCapable = Array.from(document.querySelectorAll('input[type="file"]'))
    .some(element => !element.disabled);
  return {{
    status: 'ok',
    messages,
    ...(items == null ? {{}} : {{items}}),
    extractionStrategy,
    activity: streaming ? 'streaming' : 'idle',
    isPartial: bodyText.includes('Loading older messages…'),
    attachmentCapable
  }};
}})()
"""
