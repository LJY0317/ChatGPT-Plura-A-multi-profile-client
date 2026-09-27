from __future__ import annotations

from dataclasses import dataclass
import base64
import hashlib
import json
from pathlib import Path
import secrets
import socket
import sqlite3
import struct
from typing import Any
from urllib.parse import urlsplit

from .plura_desktop import SharedSession, Target, TargetRuntime


MAX_WEBSOCKET_MESSAGE_BYTES = 1024 * 1024
MAX_CATALOG_ROWS = 250
MAX_GLOBAL_STATE_BYTES = 4 * 1024 * 1024


class ChatCatalogUnavailable(RuntimeError):
    pass


@dataclass(frozen=True)
class _ProjectMetadata:
    name: str
    pinned: bool
    sort_order: int | None


class TargetChatCatalogProvider:
    """Read the official Desktop's already-synchronized conversation catalog.

    The provider never reads browser cookies or authentication files. It learns
    CODEX_HOME from the canonical app-server's initialize response and then
    opens only the Desktop catalog database/global-state files beneath that
    directory. The HTTP bridge returns a deliberately small, content-free view.
    """

    def __init__(self, runtime: TargetRuntime) -> None:
        self.runtime = runtime
        self._codex_homes: dict[str, tuple[str, Path]] = {}
        self._snapshots: dict[str, tuple[SharedSession, dict[str, Any]]] = {}

    def cached_snapshot(self, target: Target) -> tuple[SharedSession, dict[str, Any]] | None:
        snapshot = self._snapshots.get(target.id)
        session = self.runtime.cached_session(target)
        if snapshot is None or session is None:
            return None
        snapshot_session, payload = snapshot
        if (
            snapshot_session.endpoint != session.endpoint
            or snapshot_session.renderer_cdp_endpoint != session.renderer_cdp_endpoint
        ):
            return None
        return session, payload

    def __call__(self, target: Target) -> dict[str, Any]:
        session = self.runtime.session(target)
        if session is None:
            raise ChatCatalogUnavailable("target-not-ready")
        cached = self._codex_homes.get(target.id)
        if cached is None or cached[0] != session.endpoint:
            codex_home = _discover_codex_home(session.endpoint)
            self._codex_homes[target.id] = (session.endpoint, codex_home)
        else:
            codex_home = cached[1]
        try:
            payload = _read_catalog(codex_home)
            self._snapshots[target.id] = (session, payload)
            return payload
        except (OSError, sqlite3.Error, ValueError, json.JSONDecodeError) as error:
            raise ChatCatalogUnavailable("desktop-catalog-unavailable") from error


def _discover_codex_home(endpoint: str) -> Path:
    parsed = urlsplit(endpoint)
    if parsed.scheme != "ws" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"} or parsed.port is None:
        raise ChatCatalogUnavailable("invalid-app-server-endpoint")
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise ChatCatalogUnavailable("invalid-app-server-endpoint")

    host = parsed.hostname
    with socket.create_connection((host, parsed.port), timeout=4) as sock:
        sock.settimeout(4)
        key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        host_header = f"[{host}]:{parsed.port}" if ":" in host else f"{host}:{parsed.port}"
        request = (
            "GET / HTTP/1.1\r\n"
            f"Host: {host_header}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        ).encode("ascii")
        sock.sendall(request)
        header, remainder = _read_http_upgrade(sock)
        status = header.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            raise ChatCatalogUnavailable("app-server-websocket-upgrade-failed")
        expected = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        accept = _header_value(header, b"sec-websocket-accept")
        if accept != expected:
            raise ChatCatalogUnavailable("app-server-websocket-accept-mismatch")

        initialize = {
            "method": "initialize",
            "id": 1,
            "params": {
                "clientInfo": {
                    "name": "PluraHost",
                    "title": "Plura Host",
                    "version": "0.1",
                },
                "capabilities": {"experimentalApi": True, "requestAttestation": False},
            },
        }
        _send_frame(sock, 0x1, json.dumps(initialize, separators=(",", ":")).encode("utf-8"))
        buffered = bytearray(remainder)
        while True:
            opcode, payload = _read_message(sock, buffered)
            if opcode == 0x8:
                raise ChatCatalogUnavailable("app-server-closed-during-initialize")
            if opcode != 0x1:
                continue
            message = json.loads(payload.decode("utf-8"))
            if message.get("id") != 1:
                continue
            result = message.get("result")
            if not isinstance(result, dict):
                raise ChatCatalogUnavailable("invalid-initialize-response")
            value = result.get("codexHome")
            if not isinstance(value, str) or not value:
                raise ChatCatalogUnavailable("initialize-missing-codex-home")
            codex_home = Path(value)
            if not codex_home.is_absolute() or not codex_home.is_dir():
                raise ChatCatalogUnavailable("invalid-codex-home")
            return codex_home


def _read_http_upgrade(sock: socket.socket) -> tuple[bytes, bytes]:
    data = bytearray()
    marker = b"\r\n\r\n"
    while marker not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise ChatCatalogUnavailable("app-server-closed-before-upgrade")
        data.extend(chunk)
        if len(data) > 64 * 1024:
            raise ChatCatalogUnavailable("app-server-upgrade-header-too-large")
    header, remainder = bytes(data).split(marker, 1)
    return header, remainder


def _header_value(header: bytes, name: bytes) -> str | None:
    for line in header.split(b"\r\n")[1:]:
        key, sep, value = line.partition(b":")
        if sep and key.strip().lower() == name:
            return value.strip().decode("ascii", "strict")
    return None


def _send_frame(sock: socket.socket, opcode: int, payload: bytes) -> None:
    if len(payload) > MAX_WEBSOCKET_MESSAGE_BYTES:
        raise ChatCatalogUnavailable("websocket-message-too-large")
    first = 0x80 | (opcode & 0x0F)
    length = len(payload)
    if length < 126:
        header = bytes([first, 0x80 | length])
    elif length <= 0xFFFF:
        header = bytes([first, 0x80 | 126]) + struct.pack("!H", length)
    else:
        header = bytes([first, 0x80 | 127]) + struct.pack("!Q", length)
    mask = secrets.token_bytes(4)
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    sock.sendall(header + mask + masked)


def _recv_exact(sock: socket.socket, buffered: bytearray, count: int) -> bytes:
    while len(buffered) < count:
        chunk = sock.recv(max(4096, count - len(buffered)))
        if not chunk:
            raise ChatCatalogUnavailable("app-server-websocket-closed")
        buffered.extend(chunk)
    value = bytes(buffered[:count])
    del buffered[:count]
    return value


def _read_frame(sock: socket.socket, buffered: bytearray) -> tuple[bool, int, bytes]:
    first, second = _recv_exact(sock, buffered, 2)
    final = bool(first & 0x80)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", _recv_exact(sock, buffered, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", _recv_exact(sock, buffered, 8))[0]
    if length > MAX_WEBSOCKET_MESSAGE_BYTES:
        raise ChatCatalogUnavailable("websocket-message-too-large")
    mask = _recv_exact(sock, buffered, 4) if masked else b""
    payload = _recv_exact(sock, buffered, length)
    if masked:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return final, opcode, payload


def _read_message(sock: socket.socket, buffered: bytearray) -> tuple[int, bytes]:
    fragments = bytearray()
    message_opcode: int | None = None
    while True:
        final, opcode, payload = _read_frame(sock, buffered)
        if opcode == 0x8:
            return opcode, payload
        if opcode == 0x9:
            _send_frame(sock, 0xA, payload)
            continue
        if opcode == 0xA:
            continue
        if opcode in {0x1, 0x2}:
            message_opcode = opcode
            fragments = bytearray(payload)
        elif opcode == 0x0 and message_opcode is not None:
            fragments.extend(payload)
        else:
            raise ChatCatalogUnavailable("invalid-websocket-frame")
        if len(fragments) > MAX_WEBSOCKET_MESSAGE_BYTES:
            raise ChatCatalogUnavailable("websocket-message-too-large")
        if final and message_opcode is not None:
            return message_opcode, bytes(fragments)


def _read_catalog(codex_home: Path) -> dict[str, Any]:
    database = codex_home / "sqlite" / "codex-dev.db"
    if database.is_symlink() or not database.is_file():
        raise ChatCatalogUnavailable("desktop-catalog-database-missing")
    connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=2)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA query_only = ON")
        columns = {row[1] for row in connection.execute("PRAGMA table_info(local_thread_catalog)")}
        required = {
            "host_id", "thread_id", "display_title", "source_kind", "source_created_at", "source_recency_at",
            "project_id", "missing_candidate",
        }
        if not required.issubset(columns):
            raise ChatCatalogUnavailable("unsupported-desktop-catalog-schema")
        host_row = connection.execute(
            """
            SELECT h.host_id
            FROM local_thread_catalog_hosts AS h
            LEFT JOIN local_thread_catalog_sync_state AS s ON s.host_id = h.host_id
            WHERE h.host_kind = 'chatgpt'
            ORDER BY COALESCE(s.last_full_reconciled_at, 0) DESC,
                     COALESCE(s.watermark_updated_at, 0) DESC,
                     h.host_id DESC
            LIMIT 1
            """
        ).fetchone()
        chatgpt_host = host_row["host_id"] if host_row is not None else None
        account_id = _account_id_from_host(chatgpt_host)
        projects, pinned_conversations = _read_project_metadata(codex_home, account_id)
        rows = connection.execute(
            """
            SELECT c.thread_id, c.display_title, c.source_kind, c.source_recency_at,
                   c.project_id, h.host_kind
            FROM local_thread_catalog AS c
            JOIN local_thread_catalog_hosts AS h ON h.host_id = c.host_id
            WHERE c.missing_candidate = 0
              AND h.host_kind IN ('local', 'chatgpt')
              AND (h.host_kind != 'chatgpt' OR c.host_id = ?)
            ORDER BY c.source_recency_at DESC, c.source_created_at DESC, c.thread_id
            LIMIT ?
            """,
            (chatgpt_host or "", MAX_CATALOG_ROWS),
        ).fetchall()
        entries = []
        for row in rows:
            project_id = row["project_id"] if isinstance(row["project_id"], str) else None
            project = projects.get(project_id) if project_id else None
            if row["host_kind"] == "chatgpt" and project_id and projects and project is None:
                # The thread catalog can retain rows for projects that are no
                # longer in the active ChatGPT sidebar project set. Match the
                # Desktop sidebar rather than reviving those stale groups.
                continue
            entries.append(
                {
                    "id": row["thread_id"],
                    "title": row["display_title"],
                    "updatedAt": row["source_recency_at"],
                    "sourceKind": row["source_kind"],
                    "projectId": project_id,
                    "projectName": project.name if project else None,
                    "isPinned": row["thread_id"] in pinned_conversations,
                    "canOpenRemotely": row["host_kind"] == "local",
                }
            )
        project_payload = [
            {
                "id": project_id,
                "name": metadata.name,
                "isPinned": metadata.pinned,
                "sortOrder": metadata.sort_order,
            }
            for project_id, metadata in sorted(
                projects.items(),
                key=lambda item: (
                    item[1].sort_order is None,
                    item[1].sort_order if item[1].sort_order is not None else 0,
                    item[1].name.casefold(),
                ),
            )
        ]
        return {
            "contractVersion": 1,
            "entries": entries,
            "projects": project_payload,
        }
    finally:
        connection.close()


def _account_id_from_host(host_id: str | None) -> str | None:
    if not host_id:
        return None
    parts = host_id.split(":", 2)
    if len(parts) != 3 or parts[0] != "chatgpt" or not parts[1]:
        return None
    return parts[1]


def _read_project_metadata(
    codex_home: Path,
    account_id: str | None,
) -> tuple[dict[str, _ProjectMetadata], set[str]]:
    if account_id is None:
        return {}, set()
    state_path = codex_home / ".codex-global-state.json"
    if state_path.is_symlink() or not state_path.is_file():
        return {}, set()
    if state_path.stat().st_size > MAX_GLOBAL_STATE_BYTES:
        raise ChatCatalogUnavailable("desktop-global-state-too-large")
    payload = json.loads(state_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        return {}, set()
    atom = payload.get("electron-persisted-atom-state")
    if not isinstance(atom, dict):
        return {}, set()
    sidebar = atom.get("chatgpt-sidebar-state-v1")
    if not isinstance(sidebar, dict):
        return {}, set()
    account = sidebar.get(account_id)
    if not isinstance(account, dict):
        return {}, set()

    projects: dict[str, _ProjectMetadata] = {}
    for raw in account.get("projects", []):
        if not isinstance(raw, dict):
            continue
        project_id = raw.get("id")
        name = raw.get("name")
        if isinstance(project_id, str) and project_id.startswith("g-p-") and isinstance(name, str) and name.strip():
            projects[project_id] = _ProjectMetadata(name.strip(), False, None)
    for item in account.get("pinnedProjects", []):
        if not isinstance(item, dict):
            continue
        raw = item.get("project")
        if not isinstance(raw, dict):
            continue
        project_id = raw.get("id")
        name = raw.get("name")
        if isinstance(project_id, str) and project_id.startswith("g-p-") and isinstance(name, str) and name.strip():
            projects[project_id] = _ProjectMetadata(name.strip(), True, None)

    pinned_order = atom.get("unified-sidebar-pinned-order-v1")
    if isinstance(pinned_order, list):
        for index, raw in enumerate(pinned_order):
            if not isinstance(raw, str) or not raw.startswith("chatgpt:project:"):
                continue
            project_id = raw.removeprefix("chatgpt:project:")
            existing = projects.get(project_id)
            if existing is not None:
                projects[project_id] = _ProjectMetadata(existing.name, True, index)

    pinned_conversations: set[str] = set()
    for item in account.get("pinnedConversations", []):
        if not isinstance(item, dict):
            continue
        raw = item.get("conversation") if isinstance(item.get("conversation"), dict) else item
        conversation_id = None
        if isinstance(raw, dict):
            conversation_id = raw.get("id") or raw.get("conversationId") or raw.get("conversation_id")
        if isinstance(conversation_id, str) and conversation_id:
            pinned_conversations.add(conversation_id)
    return projects, pinned_conversations
