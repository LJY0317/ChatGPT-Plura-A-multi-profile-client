from __future__ import annotations

import asyncio
from collections import OrderedDict
from dataclasses import dataclass
import hashlib
import hmac
import json
from pathlib import Path
import re
from typing import Callable
from urllib.parse import unquote, urlsplit

from .attachments import (
    ChatAttachmentStore,
    MAX_CHAT_ATTACHMENT_BYTES,
    MAX_CHAT_ATTACHMENTS_PER_MESSAGE,
    StagedChatAttachment,
)
from .plura_desktop import Target, TargetRuntime
from .network import ConnectionEndpoint


MAX_HEADER_BYTES = 64 * 1024
MAX_JSON_BODY_BYTES = 64 * 1024
MAX_CHAT_SEND_CACHE_ENTRIES = 128


@dataclass
class PairingState:
    bootstrap_token: str
    capability_token: str
    token_file: Path
    used: bool = False


async def read_request(reader: asyncio.StreamReader) -> tuple[bytes, bytes]:
    data = bytearray()
    marker = b"\r\n\r\n"
    while marker not in data:
        chunk = await reader.read(4096)
        if not chunk:
            raise ConnectionError("client closed before HTTP request completed")
        data.extend(chunk)
        if len(data) > MAX_HEADER_BYTES:
            raise ConnectionError("HTTP request header is too large")
    header, remainder = bytes(data).split(marker, 1)
    return header, remainder


def parse_request(header: bytes) -> tuple[str, str, list[bytes]]:
    lines = header.split(b"\r\n")
    parts = lines[0].split(b" ") if lines else []
    if len(parts) != 3 or parts[2] != b"HTTP/1.1":
        raise ConnectionError("invalid HTTP request line")
    return parts[0].decode("ascii"), parts[1].decode("ascii"), lines[1:]


def authorization_value(lines: list[bytes]) -> str | None:
    for line in lines:
        name, sep, value = line.partition(b":")
        if sep and name.strip().lower() == b"authorization":
            return value.strip().decode("ascii", "strict")
    return None


def header_value(lines: list[bytes], expected_name: str) -> str | None:
    expected = expected_name.encode("ascii").lower()
    values: list[str] = []
    for line in lines:
        name, sep, value = line.partition(b":")
        if not sep or name.strip().lower() != expected:
            continue
        values.append(value.strip().decode("latin-1", "strict"))
    if not values:
        return None
    if any(value != values[0] for value in values[1:]):
        raise ConnectionError(f"conflicting {expected_name} headers")
    return values[0]


def content_length_value(lines: list[bytes]) -> int | None:
    values: list[int] = []
    for line in lines:
        name, sep, value = line.partition(b":")
        if not sep or name.strip().lower() != b"content-length":
            continue
        try:
            parsed = int(value.strip().decode("ascii", "strict"))
        except (UnicodeError, ValueError) as error:
            raise ConnectionError("invalid Content-Length") from error
        if parsed < 0:
            raise ConnectionError("invalid Content-Length")
        values.append(parsed)
    if not values:
        return None
    if any(value != values[0] for value in values[1:]):
        raise ConnectionError("conflicting Content-Length headers")
    return values[0]


async def read_json_body(
    reader: asyncio.StreamReader,
    remainder: bytes,
    lines: list[bytes],
) -> dict[str, object]:
    body = await read_body(reader, remainder, lines, max_bytes=MAX_JSON_BODY_BYTES)
    payload = json.loads(body.decode("utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("JSON request body must be an object")
    return payload


async def read_body(
    reader: asyncio.StreamReader,
    remainder: bytes,
    lines: list[bytes],
    *,
    max_bytes: int,
) -> bytes:
    length = content_length_value(lines)
    if length is None or length <= 0 or length > max_bytes:
        raise ValueError("invalid HTTP body length")
    body = bytearray(remainder[:length])
    while len(body) < length:
        chunk = await reader.read(length - len(body))
        if not chunk:
            raise ConnectionError("client closed before HTTP body completed")
        body.extend(chunk)
    return bytes(body)


async def send_response(
    writer: asyncio.StreamWriter,
    status: str,
    *,
    content_type: str = "application/json; charset=utf-8",
    body: bytes = b"",
) -> None:
    header = (
        f"HTTP/1.1 {status}\r\n"
        "Connection: close\r\n"
        "Cache-Control: no-store\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "\r\n"
    ).encode("ascii")
    writer.write(header + body)
    await writer.drain()


def backend_upgrade_header(lines: list[bytes], port: int) -> bytes:
    forwarded = [b"GET / HTTP/1.1"]
    for line in lines:
        name, sep, _ = line.partition(b":")
        if not sep:
            continue
        if name.strip().lower() in {b"authorization", b"host"}:
            continue
        forwarded.append(line)
    forwarded.append(f"Host: 127.0.0.1:{port}".encode("ascii"))
    return b"\r\n".join(forwarded) + b"\r\n\r\n"


async def relay(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while chunk := await reader.read(64 * 1024):
            writer.write(chunk)
            await writer.drain()
    finally:
        try:
            writer.write_eof()
        except (AttributeError, OSError, RuntimeError):
            pass


class BridgeServer:
    def __init__(
        self,
        runtime: TargetRuntime,
        capability_token: str,
        pairing: PairingState | None,
        endpoints: list[ConnectionEndpoint] | None = None,
        endpoint_provider: Callable[[], list[ConnectionEndpoint]] | None = None,
        chat_catalog_provider: Callable[[Target], dict[str, object]] | None = None,
        chat_transcript_provider: Callable[[Target, str], dict[str, object]] | None = None,
        chat_message_provider: Callable[
            [Target, str, str, str, list[StagedChatAttachment]],
            dict[str, object],
        ] | None = None,
        chat_attachment_store: ChatAttachmentStore | None = None,
    ) -> None:
        self.runtime = runtime
        self.capability_token = capability_token
        self.pairing = pairing
        self.endpoints = list(endpoints or [])
        self.endpoint_provider = endpoint_provider
        self.chat_catalog_provider = chat_catalog_provider
        self.chat_transcript_provider = chat_transcript_provider
        self.chat_message_provider = chat_message_provider
        self.chat_attachment_store = chat_attachment_store or ChatAttachmentStore()
        self._activation_locks: dict[str, asyncio.Lock] = {}
        self._chat_transcript_locks: dict[str, asyncio.Lock] = {}
        self._chat_send_cache: OrderedDict[tuple[str, str], tuple[str, dict[str, object]]] = OrderedDict()

    def _connection_endpoints(self) -> list[ConnectionEndpoint]:
        if self.endpoint_provider is None:
            return list(self.endpoints)
        try:
            return list(self.endpoint_provider())
        except (OSError, RuntimeError, ValueError):
            return list(self.endpoints)

    def close(self) -> None:
        self.chat_attachment_store.close()

    def _authorized(self, lines: list[bytes]) -> bool:
        supplied = authorization_value(lines)
        expected = f"Bearer {self.capability_token}"
        return supplied is not None and hmac.compare_digest(supplied, expected)

    def _target_by_route(self, route_key: str) -> Target | None:
        return next((target for target in self.runtime.targets() if target.route_key == route_key), None)

    def _targets_payload(self) -> bytes:
        data = []
        for target in self.runtime.targets(refresh=True):
            data.append(
                {
                    "id": target.id,
                    "displayName": target.display_name,
                    "role": target.role,
                    "route": f"/targets/{target.route_key}/ws",
                    "activationState": self.runtime.activation_state(target),
                    "chatMirrorState": self.runtime.renderer_state(target),
                }
            )
        return json.dumps({"contractVersion": 1, "targets": data}, sort_keys=True).encode("utf-8")

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        backend_writer: asyncio.StreamWriter | None = None
        try:
            header, remainder = await read_request(reader)
            method, raw_path, lines = parse_request(header)
            path = raw_path.split("?", 1)[0]

            if method == "GET" and path == "/pair":
                pairing = self.pairing
                supplied = authorization_value(lines)
                if pairing is None or pairing.used:
                    await send_response(writer, "404 Not Found")
                    return
                if supplied is None or not hmac.compare_digest(supplied, f"Bearer {pairing.bootstrap_token}"):
                    await send_response(writer, "401 Unauthorized")
                    return
                pairing.used = True
                try:
                    pairing.token_file.unlink()
                except FileNotFoundError:
                    pass
                await send_response(
                    writer,
                    "200 OK",
                    body=json.dumps(
                        {
                            "contractVersion": 2,
                            "capabilityToken": pairing.capability_token,
                            "endpoints": [endpoint.public() for endpoint in self._connection_endpoints()],
                        },
                        sort_keys=True,
                    ).encode("utf-8"),
                )
                return

            if not self._authorized(lines):
                await send_response(writer, "401 Unauthorized")
                return

            if method == "GET" and path == "/ping":
                await send_response(
                    writer,
                    "200 OK",
                    body=json.dumps({"contractVersion": 1}, sort_keys=True).encode("utf-8"),
                )
                return

            if method == "GET" and path == "/targets":
                await send_response(writer, "200 OK", body=self._targets_payload())
                return

            if method == "GET" and path == "/connection-info":
                await send_response(
                    writer,
                    "200 OK",
                    body=json.dumps(
                        {
                            "contractVersion": 1,
                            "endpoints": [endpoint.public() for endpoint in self._connection_endpoints()],
                        },
                        sort_keys=True,
                    ).encode("utf-8"),
                )
                return

            parts = [part for part in path.split("/") if part]
            if len(parts) == 3 and parts[0] == "targets" and parts[2] == "activate" and method == "POST":
                target = self._target_by_route(parts[1])
                if target is None:
                    await send_response(writer, "404 Not Found")
                    return
                lock = self._activation_locks.setdefault(target.id, asyncio.Lock())
                async with lock:
                    try:
                        session = await asyncio.to_thread(
                            self.runtime.activate,
                            target,
                            request_renderer_cdp=True,
                        )
                    except RuntimeError as error:
                        reason = str(error)
                        status = "409 Conflict" if reason in {
                            "restart-required",
                            "renderer-cdp-restart-required",
                            "unsupported",
                            "unavailable",
                        } else "503 Service Unavailable"
                        await send_response(writer, status, body=json.dumps({"error": reason}).encode("utf-8"))
                        return
                await send_response(
                    writer,
                    "200 OK",
                    body=json.dumps({"state": "ready", "endpoint": session.endpoint}).encode("utf-8"),
                )
                return

            if len(parts) == 3 and parts[0] == "targets" and parts[2] == "chat-prepare" and method == "POST":
                target = self._target_by_route(parts[1])
                if target is None:
                    await send_response(writer, "404 Not Found")
                    return
                try:
                    request = await read_json_body(reader, remainder, lines)
                    allow_relaunch = request.get("allowRelaunch") is True
                except (ConnectionError, UnicodeError, ValueError, json.JSONDecodeError):
                    await send_response(writer, "400 Bad Request", body=b'{"error":"chat-prepare-invalid"}')
                    return
                lock = self._activation_locks.setdefault(target.id, asyncio.Lock())
                async with lock:
                    try:
                        session = await asyncio.to_thread(
                            self.runtime.prepare_chat,
                            target,
                            allow_relaunch=allow_relaunch,
                        )
                    except RuntimeError as error:
                        reason = str(error).strip() or "chat-mirror-unavailable"
                        if not re.fullmatch(r"[a-z0-9-]{1,96}", reason):
                            reason = "chat-mirror-unavailable"
                        status = "409 Conflict" if reason in {
                            "chat-relaunch-required",
                            "restart-required",
                            "unsupported",
                            "unavailable",
                        } else "503 Service Unavailable"
                        await send_response(
                            writer,
                            status,
                            body=json.dumps({"error": reason}, sort_keys=True).encode("utf-8"),
                        )
                        return
                await send_response(
                    writer,
                    "200 OK",
                    body=json.dumps(
                        {
                            "state": "ready",
                            "chatMirrorState": "ready",
                            "endpoint": session.endpoint,
                        },
                        sort_keys=True,
                    ).encode("utf-8"),
                )
                return

            if len(parts) == 3 and parts[0] == "targets" and parts[2] == "chat-catalog" and method == "GET":
                target = self._target_by_route(parts[1])
                if target is None:
                    await send_response(writer, "404 Not Found")
                    return
                if self.chat_catalog_provider is None:
                    await send_response(writer, "503 Service Unavailable", body=b'{"error":"chat-catalog-unavailable"}')
                    return
                try:
                    payload = await asyncio.to_thread(self.chat_catalog_provider, target)
                except (OSError, RuntimeError, ValueError):
                    await send_response(writer, "503 Service Unavailable", body=b'{"error":"chat-catalog-unavailable"}')
                    return
                await send_response(
                    writer,
                    "200 OK",
                    body=json.dumps(payload, sort_keys=True).encode("utf-8"),
                )
                return

            if len(parts) == 3 and parts[0] == "targets" and parts[2] == "chat-attachments" and method == "POST":
                target = self._target_by_route(parts[1])
                if target is None:
                    await send_response(writer, "404 Not Found")
                    return
                if self.chat_message_provider is None:
                    await send_response(writer, "503 Service Unavailable", body=b'{"error":"chat-write-unavailable"}')
                    return
                try:
                    length = content_length_value(lines)
                    encoded_filename = header_value(lines, "X-Plura-Filename")
                    mime_type = header_value(lines, "Content-Type") or "application/octet-stream"
                    if length is None or length <= 0 or encoded_filename is None or len(encoded_filename) > 1024:
                        raise ValueError("chat-attachment-invalid")
                    if length > MAX_CHAT_ATTACHMENT_BYTES:
                        await send_response(
                            writer,
                            "413 Payload Too Large",
                            body=b'{"error":"chat-attachment-too-large"}',
                        )
                        return
                    filename = unquote(encoded_filename, encoding="utf-8", errors="strict")
                    data = await read_body(reader, remainder, lines, max_bytes=MAX_CHAT_ATTACHMENT_BYTES)
                    attachment = self.chat_attachment_store.stage(
                        target.id,
                        filename,
                        mime_type,
                        data,
                    )
                except (ConnectionError, UnicodeError, ValueError) as error:
                    reason = str(error).strip()
                    if reason not in {
                        "chat-attachment-invalid",
                        "chat-attachment-too-large",
                        "chat-attachment-capacity",
                    }:
                        reason = "chat-attachment-invalid"
                    status = "413 Payload Too Large" if reason in {
                        "chat-attachment-too-large",
                        "chat-attachment-capacity",
                    } else "400 Bad Request"
                    await send_response(
                        writer,
                        status,
                        body=json.dumps({"error": reason}, sort_keys=True).encode("utf-8"),
                    )
                    return
                await send_response(
                    writer,
                    "200 OK",
                    body=json.dumps(attachment.public(), sort_keys=True).encode("utf-8"),
                )
                return

            if len(parts) == 4 and parts[0] == "targets" and parts[2] == "chat-conversations" and method == "GET":
                target = self._target_by_route(parts[1])
                conversation_id = parts[3]
                if target is None or not conversation_id:
                    await send_response(writer, "404 Not Found")
                    return
                if self.chat_transcript_provider is None:
                    await send_response(writer, "503 Service Unavailable", body=b'{"error":"chat-transcript-unavailable"}')
                    return
                try:
                    lock = self._chat_transcript_locks.setdefault(target.id, asyncio.Lock())
                    async with lock:
                        payload = await asyncio.to_thread(self.chat_transcript_provider, target, conversation_id)
                except (OSError, RuntimeError, ValueError) as error:
                    reason = str(error).strip() or "chat-transcript-unavailable"
                    if not re.fullmatch(r"[a-z0-9-]{1,96}", reason):
                        reason = "chat-transcript-unavailable"
                    status = "409 Conflict" if reason in {
                        "target-not-ready",
                        "desktop-renderer-unavailable",
                        "conversation-row-unavailable",
                        "conversation-row-not-actionable",
                    } else "503 Service Unavailable"
                    await send_response(
                        writer,
                        status,
                        body=json.dumps({"error": reason}, sort_keys=True).encode("utf-8"),
                    )
                    return
                await send_response(
                    writer,
                    "200 OK",
                    body=json.dumps(payload, sort_keys=True).encode("utf-8"),
                )
                return

            if (
                len(parts) == 5
                and parts[0] == "targets"
                and parts[2] == "chat-conversations"
                and parts[4] == "messages"
                and method == "POST"
            ):
                target = self._target_by_route(parts[1])
                conversation_id = parts[3]
                if target is None or not conversation_id:
                    await send_response(writer, "404 Not Found")
                    return
                if self.chat_message_provider is None:
                    await send_response(writer, "503 Service Unavailable", body=b'{"error":"chat-write-unavailable"}')
                    return
                try:
                    request = await read_json_body(reader, remainder, lines)
                except (ConnectionError, UnicodeError, ValueError, json.JSONDecodeError):
                    await send_response(writer, "400 Bad Request", body=b'{"error":"chat-message-invalid"}')
                    return
                client_request_id = request.get("clientRequestId")
                text = request.get("text")
                attachment_ids = request.get("attachmentIds", [])
                if (
                    request.get("contractVersion") != 1
                    or not isinstance(client_request_id, str)
                    or not re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", client_request_id)
                    or not isinstance(text, str)
                    or len(text.strip()) > 32 * 1024
                    or not isinstance(attachment_ids, list)
                    or len(attachment_ids) > MAX_CHAT_ATTACHMENTS_PER_MESSAGE
                    or not all(
                        isinstance(value, str)
                        and re.fullmatch(r"[A-Za-z0-9_-]{16,64}", value)
                        for value in attachment_ids
                    )
                    or len(set(attachment_ids)) != len(attachment_ids)
                    or (not text.strip() and not attachment_ids)
                ):
                    await send_response(writer, "400 Bad Request", body=b'{"error":"chat-message-invalid"}')
                    return
                normalized_text = text.strip()
                fingerprint = hashlib.sha256(json.dumps(
                    {
                        "conversationId": conversation_id,
                        "text": normalized_text,
                        "attachmentIds": attachment_ids,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode("utf-8")).hexdigest()
                cache_key = (target.id, client_request_id)
                cached = self._chat_send_cache.get(cache_key)
                if cached is not None:
                    cached_fingerprint, cached_payload = cached
                    if cached_fingerprint != fingerprint:
                        await send_response(
                            writer,
                            "409 Conflict",
                            body=b'{"error":"client-request-id-conflict"}',
                        )
                        return
                    self._chat_send_cache.move_to_end(cache_key)
                    await send_response(
                        writer,
                        "200 OK",
                        body=json.dumps(cached_payload, sort_keys=True).encode("utf-8"),
                    )
                    return

                lock = self._chat_transcript_locks.setdefault(target.id, asyncio.Lock())
                async with lock:
                    cached = self._chat_send_cache.get(cache_key)
                    if cached is not None:
                        cached_fingerprint, cached_payload = cached
                        if cached_fingerprint != fingerprint:
                            await send_response(
                                writer,
                                "409 Conflict",
                                body=b'{"error":"client-request-id-conflict"}',
                            )
                            return
                        self._chat_send_cache.move_to_end(cache_key)
                        await send_response(
                            writer,
                            "200 OK",
                            body=json.dumps(cached_payload, sort_keys=True).encode("utf-8"),
                        )
                        return
                    try:
                        attachments = self.chat_attachment_store.resolve_many(target.id, attachment_ids)
                    except ValueError as error:
                        reason = str(error).strip() or "chat-attachment-unavailable"
                        if reason not in {
                            "chat-attachment-invalid",
                            "chat-attachment-count-invalid",
                            "chat-attachment-unavailable",
                        }:
                            reason = "chat-attachment-unavailable"
                        await send_response(
                            writer,
                            "409 Conflict",
                            body=json.dumps({"error": reason}, sort_keys=True).encode("utf-8"),
                        )
                        return
                    try:
                        payload = await asyncio.to_thread(
                            self.chat_message_provider,
                            target,
                            conversation_id,
                            normalized_text,
                            client_request_id,
                            attachments,
                        )
                    except (OSError, RuntimeError, ValueError) as error:
                        reason = str(error).strip() or "chat-write-unavailable"
                        if not re.fullmatch(r"[a-z0-9-]{1,96}", reason):
                            reason = "chat-write-unavailable"
                        conflict_reasons = {
                            "target-not-ready",
                            "conversation-not-in-catalog",
                            "conversation-is-local-thread",
                            "desktop-renderer-unavailable",
                            "desktop-renderer-ambiguous",
                            "conversation-row-unavailable",
                            "conversation-row-not-actionable",
                            "conversation-changed-before-submit",
                            "desktop-composer-unavailable",
                            "desktop-composer-draft-present",
                            "desktop-conversation-busy",
                            "desktop-composer-changed",
                            "desktop-composer-send-unavailable",
                            "desktop-attachment-input-unavailable",
                            "desktop-attachment-input-ambiguous",
                            "desktop-attachment-draft-present",
                            "desktop-attachment-changed",
                        }
                        status = "409 Conflict" if reason in conflict_reasons else "503 Service Unavailable"
                        body: dict[str, object] = {"error": reason}
                        if reason == "chat-send-uncertain":
                            body["retrySafe"] = False
                        await send_response(
                            writer,
                            status,
                            body=json.dumps(body, sort_keys=True).encode("utf-8"),
                        )
                        return
                    self.chat_attachment_store.remove_many(attachment_ids)
                    self._chat_send_cache[cache_key] = (fingerprint, payload)
                    self._chat_send_cache.move_to_end(cache_key)
                    while len(self._chat_send_cache) > MAX_CHAT_SEND_CACHE_ENTRIES:
                        self._chat_send_cache.popitem(last=False)
                await send_response(
                    writer,
                    "200 OK",
                    body=json.dumps(payload, sort_keys=True).encode("utf-8"),
                )
                return

            if len(parts) == 3 and parts[0] == "targets" and parts[2] == "ws" and method == "GET":
                target = self._target_by_route(parts[1])
                if target is None:
                    await send_response(writer, "404 Not Found")
                    return
                session = self.runtime.session(target)
                if session is None:
                    await send_response(writer, "409 Conflict", body=b'{"error":"target-not-ready"}')
                    return
                parsed = urlsplit(session.endpoint)
                if parsed.hostname != "127.0.0.1" or parsed.port is None:
                    await send_response(writer, "503 Service Unavailable")
                    return
                backend_reader, backend_writer = await asyncio.open_connection("127.0.0.1", parsed.port)
                backend_writer.write(backend_upgrade_header(lines, parsed.port))
                if remainder:
                    backend_writer.write(remainder)
                await backend_writer.drain()
                client_to_backend = asyncio.create_task(relay(reader, backend_writer))
                backend_to_client = asyncio.create_task(relay(backend_reader, writer))
                done, pending = await asyncio.wait(
                    {client_to_backend, backend_to_client},
                    return_when=asyncio.FIRST_COMPLETED,
                )
                for task in pending:
                    task.cancel()
                await asyncio.gather(*done, *pending, return_exceptions=True)
                return

            await send_response(writer, "404 Not Found")
        except (ConnectionError, OSError, UnicodeError, RuntimeError, json.JSONDecodeError):
            try:
                await send_response(writer, "500 Internal Server Error")
            except Exception:
                pass
        finally:
            writer.close()
            if backend_writer is not None:
                backend_writer.close()
            await asyncio.gather(
                writer.wait_closed(),
                *([] if backend_writer is None else [backend_writer.wait_closed()]),
                return_exceptions=True,
            )
