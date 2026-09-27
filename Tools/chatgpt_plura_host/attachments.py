from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
import secrets
import shutil
import tempfile
import time
from typing import Callable


MAX_CHAT_ATTACHMENT_BYTES = 25 * 1024 * 1024
MAX_CHAT_ATTACHMENTS_PER_MESSAGE = 4
MAX_STAGED_CHAT_ATTACHMENTS = 32
MAX_STAGED_CHAT_ATTACHMENT_BYTES = 100 * 1024 * 1024
CHAT_ATTACHMENT_TTL_SECONDS = 15 * 60


@dataclass(frozen=True)
class StagedChatAttachment:
    id: str
    target_id: str
    filename: str
    mime_type: str
    path: Path
    size: int
    sha256: str
    created_at: float

    def public(self) -> dict[str, object]:
        return {
            "contractVersion": 1,
            "attachmentId": self.id,
            "filename": self.filename,
            "mimeType": self.mime_type,
            "size": self.size,
        }


class ChatAttachmentStore:
    """Short-lived, process-local staging for renderer file inputs.

    Attachment bytes never become part of the pairing state or repository. The
    store is intentionally bounded and ephemeral: a host restart invalidates
    outstanding attachment IDs, while successful submits remove staged files
    immediately. Unused/error-path uploads expire automatically.
    """

    def __init__(
        self,
        root: Path | None = None,
        *,
        now: Callable[[], float] = time.monotonic,
    ) -> None:
        self._now = now
        self._owns_root = root is None
        if root is None:
            root = Path(tempfile.mkdtemp(prefix="chatgpt-plura-chat-attachments-"))
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self._items: dict[str, StagedChatAttachment] = {}

    def stage(
        self,
        target_id: str,
        filename: str,
        mime_type: str,
        data: bytes,
    ) -> StagedChatAttachment:
        self.cleanup_expired()
        if not target_id:
            raise ValueError("chat-attachment-invalid")
        safe_name = _safe_filename(filename)
        safe_mime = _safe_mime_type(mime_type)
        if not data or len(data) > MAX_CHAT_ATTACHMENT_BYTES:
            raise ValueError("chat-attachment-too-large")

        attachment_id = secrets.token_urlsafe(18)
        item_dir = self.root / attachment_id
        item_dir.mkdir(mode=0o700)
        path = item_dir / safe_name
        path.write_bytes(data)
        try:
            path.chmod(0o600)
        except OSError:
            pass
        item = StagedChatAttachment(
            id=attachment_id,
            target_id=target_id,
            filename=safe_name,
            mime_type=safe_mime,
            path=path,
            size=len(data),
            sha256=hashlib.sha256(data).hexdigest(),
            created_at=self._now(),
        )
        self._items[item.id] = item
        self._enforce_bounds()
        if item.id not in self._items:
            raise ValueError("chat-attachment-capacity")
        return item

    def resolve_many(self, target_id: str, attachment_ids: list[str]) -> list[StagedChatAttachment]:
        self.cleanup_expired()
        if len(attachment_ids) > MAX_CHAT_ATTACHMENTS_PER_MESSAGE:
            raise ValueError("chat-attachment-count-invalid")
        if len(set(attachment_ids)) != len(attachment_ids):
            raise ValueError("chat-attachment-invalid")
        resolved: list[StagedChatAttachment] = []
        for attachment_id in attachment_ids:
            item = self._items.get(attachment_id)
            if item is None or item.target_id != target_id or not item.path.is_file():
                raise ValueError("chat-attachment-unavailable")
            resolved.append(item)
        return resolved

    def remove_many(self, attachment_ids: list[str]) -> None:
        for attachment_id in attachment_ids:
            item = self._items.pop(attachment_id, None)
            if item is not None:
                shutil.rmtree(item.path.parent, ignore_errors=True)

    def cleanup_expired(self) -> None:
        threshold = self._now() - CHAT_ATTACHMENT_TTL_SECONDS
        expired = [item.id for item in self._items.values() if item.created_at < threshold]
        self.remove_many(expired)

    def close(self) -> None:
        self._items.clear()
        if self._owns_root:
            shutil.rmtree(self.root, ignore_errors=True)
            self._owns_root = False

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass

    def _enforce_bounds(self) -> None:
        while self._items and (
            len(self._items) > MAX_STAGED_CHAT_ATTACHMENTS
            or sum(item.size for item in self._items.values()) > MAX_STAGED_CHAT_ATTACHMENT_BYTES
        ):
            oldest = min(self._items.values(), key=lambda item: item.created_at)
            self.remove_many([oldest.id])


def _safe_filename(value: str) -> str:
    filename = Path(value.replace("\\", "/")).name.strip()
    filename = "".join(character for character in filename if character >= " " and character != "\x7f")
    filename = filename.replace("/", "_").replace(":", "_")
    if not filename or filename in {".", ".."}:
        filename = "attachment"
    if len(filename) > 180:
        suffix = Path(filename).suffix[:32]
        stem_limit = max(1, 180 - len(suffix))
        filename = filename[:stem_limit] + suffix
    return filename


def _safe_mime_type(value: str) -> str:
    mime = value.split(";", 1)[0].strip().lower()
    if (
        not mime
        or "/" not in mime
        or len(mime) > 128
        or any(character in mime for character in "\r\n\0")
    ):
        return "application/octet-stream"
    return mime
