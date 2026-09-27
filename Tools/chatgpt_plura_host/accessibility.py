from __future__ import annotations

import ctypes
from ctypes import POINTER, Structure, byref, c_bool, c_char_p, c_double, c_int, c_long, c_ulong, c_void_p
from dataclasses import dataclass
import re
import subprocess
import sys
import time
from typing import Any, Callable

from .plura_desktop import Target, TargetRuntime


MAX_ACCESSIBILITY_NODES = 20_000
MAX_ACCESSIBILITY_CHARACTERS = 6 * 1024 * 1024
MAX_MESSAGE_CHARACTERS = 2 * 1024 * 1024
TRANSCRIPT_LOAD_TIMEOUT_SECONDS = 6.0
DESKTOP_WINDOW_LOAD_TIMEOUT_SECONDS = 10.0
WEB_ACCESSIBILITY_LOAD_TIMEOUT_SECONDS = 10.0


_ENABLE_WEB_ACCESSIBILITY_SCRIPT = r'''
on run argv
    if (count of argv) < 1 then return "invalid-arguments"
    set targetPID to item 1 of argv as integer
    tell application "System Events"
        set processMatches to every application process whose unix id is targetPID
        if (count of processMatches) is 0 then return "desktop-process-unavailable"
        set desktopProcess to item 1 of processMatches
        try
            set value of attribute "AXEnhancedUserInterface" of desktopProcess to true
        on error
            return "desktop-accessibility-not-ready"
        end try
    end tell
    return "ok"
end run
'''


class ChatTranscriptUnavailable(RuntimeError):
    pass


@dataclass(frozen=True)
class _Message:
    role: str
    segments: list[str]


class _CGPoint(Structure):
    _fields_ = [("x", c_double), ("y", c_double)]


class _CGSize(Structure):
    _fields_ = [("width", c_double), ("height", c_double)]


class TargetChatAccessibilityProvider:
    """Read a cloud Chat from the official macOS Desktop's rendered AX tree.

    Plura Desktop supplies the canonical Desktop PID. The provider deliberately
    does not read browser storage, cookies, auth tokens, or private HTTP
    responses. Selecting a conversation does bring that Desktop window to the
    foreground and changes its visible chat selection.
    """

    def __init__(
        self,
        runtime: TargetRuntime,
        catalog_provider: Callable[[Target], dict[str, Any]],
        extractor: Callable[[int, str, str], dict[str, Any]] | None = None,
    ) -> None:
        self.runtime = runtime
        self.catalog_provider = catalog_provider
        self.extractor = extractor or _extract_native_transcript

    def __call__(self, target: Target, conversation_id: str) -> dict[str, Any]:
        if sys.platform != "darwin" and self.extractor is _extract_native_transcript:
            raise ChatTranscriptUnavailable("desktop-accessibility-unsupported")
        session = self.runtime.session(target)
        if session is None:
            raise ChatTranscriptUnavailable("target-not-ready")
        if session.desktop_process_id is None:
            raise ChatTranscriptUnavailable("desktop-process-unavailable")

        catalog = self.catalog_provider(target)
        entries = catalog.get("entries")
        if not isinstance(entries, list):
            raise ChatTranscriptUnavailable("desktop-catalog-unavailable")
        entry = next(
            (
                item for item in entries
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

        parsed = self.extractor(session.desktop_process_id, title, project_name or "")
        return {
            "contractVersion": 1,
            "conversationId": conversation_id,
            "title": title,
            "projectId": entry.get("projectId"),
            "projectName": project_name,
            "source": "desktop-accessibility",
            **parsed,
        }


class _MacAccessibility:
    _UTF8 = 0x08000100

    def __init__(self, pid: int) -> None:
        if sys.platform != "darwin":
            raise ChatTranscriptUnavailable("desktop-accessibility-unsupported")
        self._as = ctypes.CDLL(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        )
        self._cf = ctypes.CDLL(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        )
        self._configure()
        self._keys: dict[str, int] = {}
        if not self._as.AXIsProcessTrusted():
            raise ChatTranscriptUnavailable("desktop-accessibility-permission-required")
        self.app = self._as.AXUIElementCreateApplication(pid)
        if not self.app:
            raise ChatTranscriptUnavailable("desktop-process-unavailable")

    def _configure(self) -> None:
        self._as.AXIsProcessTrusted.argtypes = []
        self._as.AXIsProcessTrusted.restype = c_bool
        self._as.AXUIElementCreateApplication.argtypes = [c_int]
        self._as.AXUIElementCreateApplication.restype = c_void_p
        self._as.AXUIElementCopyAttributeValue.argtypes = [c_void_p, c_void_p, POINTER(c_void_p)]
        self._as.AXUIElementCopyAttributeValue.restype = c_int
        self._as.AXUIElementSetAttributeValue.argtypes = [c_void_p, c_void_p, c_void_p]
        self._as.AXUIElementSetAttributeValue.restype = c_int
        self._as.AXUIElementPerformAction.argtypes = [c_void_p, c_void_p]
        self._as.AXUIElementPerformAction.restype = c_int
        self._as.AXValueGetValue.argtypes = [c_void_p, c_int, c_void_p]
        self._as.AXValueGetValue.restype = c_bool
        self._as.CGEventCreate.argtypes = [c_void_p]
        self._as.CGEventCreate.restype = c_void_p
        self._as.CGEventGetLocation.argtypes = [c_void_p]
        self._as.CGEventGetLocation.restype = _CGPoint
        self._as.CGEventCreateMouseEvent.argtypes = [c_void_p, c_int, _CGPoint, c_int]
        self._as.CGEventCreateMouseEvent.restype = c_void_p
        self._as.CGEventPost.argtypes = [c_int, c_void_p]
        self._as.CGEventPost.restype = None

        self._cf.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_ulong]
        self._cf.CFStringCreateWithCString.restype = c_void_p
        self._cf.CFStringGetLength.argtypes = [c_void_p]
        self._cf.CFStringGetLength.restype = c_long
        self._cf.CFStringGetMaximumSizeForEncoding.argtypes = [c_long, c_ulong]
        self._cf.CFStringGetMaximumSizeForEncoding.restype = c_long
        self._cf.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_long, c_ulong]
        self._cf.CFStringGetCString.restype = c_bool
        self._cf.CFArrayGetCount.argtypes = [c_void_p]
        self._cf.CFArrayGetCount.restype = c_long
        self._cf.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_long]
        self._cf.CFArrayGetValueAtIndex.restype = c_void_p
        self._cf.CFGetTypeID.argtypes = [c_void_p]
        self._cf.CFGetTypeID.restype = c_ulong
        self._cf.CFEqual.argtypes = [c_void_p, c_void_p]
        self._cf.CFEqual.restype = c_bool
        self._cf.CFStringGetTypeID.argtypes = []
        self._cf.CFStringGetTypeID.restype = c_ulong
        self._cf.CFArrayGetTypeID.argtypes = []
        self._cf.CFArrayGetTypeID.restype = c_ulong
        self._cf.CFRetain.argtypes = [c_void_p]
        self._cf.CFRetain.restype = c_void_p
        self._cf.CFRelease.argtypes = [c_void_p]
        self._cf.CFRelease.restype = None

    def close(self) -> None:
        if self.app:
            self._cf.CFRelease(self.app)
            self.app = None
        for value in self._keys.values():
            self._cf.CFRelease(value)
        self._keys.clear()

    def _key(self, value: str) -> int:
        if value not in self._keys:
            result = self._cf.CFStringCreateWithCString(None, value.encode("utf-8"), self._UTF8)
            if not result:
                raise ChatTranscriptUnavailable("desktop-accessibility-failed")
            self._keys[value] = result
        return self._keys[value]

    def _copy_attribute(self, element: int, name: str) -> int | None:
        output = c_void_p()
        error = self._as.AXUIElementCopyAttributeValue(element, self._key(name), byref(output))
        if error != 0 or not output.value:
            return None
        return output.value

    def _string(self, value: int) -> str:
        if self._cf.CFGetTypeID(value) != self._cf.CFStringGetTypeID():
            return ""
        length = self._cf.CFStringGetLength(value)
        size = self._cf.CFStringGetMaximumSizeForEncoding(length, self._UTF8) + 1
        buffer = ctypes.create_string_buffer(max(size, 1))
        if not self._cf.CFStringGetCString(value, buffer, len(buffer), self._UTF8):
            return ""
        return buffer.value.decode("utf-8", "replace")

    def text_attribute(self, element: int, name: str) -> str:
        value = self._copy_attribute(element, name)
        if value is None:
            return ""
        try:
            return self._string(value)
        finally:
            self._cf.CFRelease(value)

    def element_attribute(self, element: int, name: str) -> int | None:
        return self._copy_attribute(element, name)

    def array_attribute(self, element: int, name: str) -> list[int]:
        value = self._copy_attribute(element, name)
        if value is None:
            return []
        try:
            if self._cf.CFGetTypeID(value) != self._cf.CFArrayGetTypeID():
                return []
            items: list[int] = []
            for index in range(self._cf.CFArrayGetCount(value)):
                item = self._cf.CFArrayGetValueAtIndex(value, index)
                if item:
                    self._cf.CFRetain(item)
                    items.append(item)
            return items
        finally:
            self._cf.CFRelease(value)

    def children(self, element: int) -> list[int]:
        return self.array_attribute(element, "AXChildren")

    def windows(self) -> list[int]:
        return self.array_attribute(self.app, "AXWindows")

    def release(self, element: int | None) -> None:
        if element:
            self._cf.CFRelease(element)

    def retain(self, element: int) -> int:
        self._cf.CFRetain(element)
        return element

    def equal(self, left: int, right: int) -> bool:
        return bool(self._cf.CFEqual(left, right))

    def bring_to_front(self) -> None:
        true_value = c_void_p.in_dll(self._cf, "kCFBooleanTrue").value
        error = self._as.AXUIElementSetAttributeValue(
            self.app,
            self._key("AXFrontmost"),
            true_value,
        )
        if error != 0:
            raise ChatTranscriptUnavailable("desktop-window-unavailable")

    def press(self, element: int) -> None:
        error = self._as.AXUIElementPerformAction(element, self._key("AXPress"))
        if error != 0:
            raise ChatTranscriptUnavailable("conversation-row-not-actionable")

    def _geometry_attribute(self, element: int, name: str, value_type: int, output: Any) -> bool:
        value = self._copy_attribute(element, name)
        if value is None:
            return False
        try:
            return bool(self._as.AXValueGetValue(value, value_type, byref(output)))
        finally:
            self._cf.CFRelease(value)

    def click(self, element: int) -> None:
        # ChatGPT's WebKit sidebar rows expose AXButton but currently advertise
        # AXShowMenu/AXScrollToVisible rather than AXPress. A direct AXPress can
        # therefore return success without changing the selected conversation.
        self._as.AXUIElementPerformAction(element, self._key("AXScrollToVisible"))
        time.sleep(0.05)
        position = _CGPoint()
        size = _CGSize()
        if not self._geometry_attribute(element, "AXPosition", 1, position) or not self._geometry_attribute(
            element, "AXSize", 2, size
        ):
            self.press(element)
            return
        if size.width <= 0 or size.height <= 0:
            raise ChatTranscriptUnavailable("conversation-row-not-actionable")

        original_event = self._as.CGEventCreate(None)
        original_position = self._as.CGEventGetLocation(original_event) if original_event else None
        if original_event:
            self._cf.CFRelease(original_event)
        center = _CGPoint(position.x + size.width / 2, position.y + size.height / 2)
        try:
            for event_type in (5, 1, 2):  # moved, left-down, left-up
                event = self._as.CGEventCreateMouseEvent(None, event_type, center, 0)
                if not event:
                    raise ChatTranscriptUnavailable("conversation-row-not-actionable")
                try:
                    self._as.CGEventPost(0, event)
                finally:
                    self._cf.CFRelease(event)
                time.sleep(0.04)
        finally:
            if original_position is not None:
                restore = self._as.CGEventCreateMouseEvent(None, 5, original_position, 0)
                if restore:
                    try:
                        self._as.CGEventPost(0, restore)
                    finally:
                        self._cf.CFRelease(restore)

    def find(
        self,
        roots: list[int],
        predicate: Callable[[int], bool],
    ) -> list[int]:
        matches: list[int] = []
        visited = 0

        def visit(element: int, depth: int) -> None:
            nonlocal visited
            if depth > 80:
                return
            visited += 1
            if visited > MAX_ACCESSIBILITY_NODES:
                raise ChatTranscriptUnavailable("desktop-accessibility-output-too-large")
            if predicate(element):
                matches.append(self.retain(element))
            children = self.children(element)
            try:
                for child in children:
                    visit(child, depth + 1)
            finally:
                for child in children:
                    self.release(child)

        try:
            for root in roots:
                visit(root, 0)
            return matches
        except Exception:
            for match in matches:
                self.release(match)
            raise

    def visit(self, root: int, callback: Callable[[int], None]) -> None:
        visited = 0

        def walk(element: int, depth: int) -> None:
            nonlocal visited
            if depth > 80:
                return
            visited += 1
            if visited > MAX_ACCESSIBILITY_NODES:
                raise ChatTranscriptUnavailable("desktop-accessibility-output-too-large")
            callback(element)
            children = self.children(element)
            try:
                for child in children:
                    walk(child, depth + 1)
            finally:
                for child in children:
                    self.release(child)

        walk(root, 0)


def _extract_native_transcript(pid: int, title: str, project_name: str) -> dict[str, Any]:
    ax = _MacAccessibility(pid)
    try:
        _wait_for_desktop_window(ax)
        ax.bring_to_front()
        _ensure_web_accessibility(ax, pid)
        windows = _desktop_windows(ax)
        if not windows:
            raise ChatTranscriptUnavailable("desktop-window-unavailable")
        try:
            target_button = _conversation_button(ax, windows, title, project_name)
            try:
                was_current = ax.text_attribute(target_button, "AXARIACurrent") == "page"
                if not was_current:
                    ax.click(target_button)
            finally:
                ax.release(target_button)
        finally:
            for window in windows:
                ax.release(window)

        if not was_current:
            navigation_deadline = time.monotonic() + TRANSCRIPT_LOAD_TIMEOUT_SECONDS
            while True:
                time.sleep(0.15)
                windows = _desktop_windows(ax)
                if not windows:
                    raise ChatTranscriptUnavailable("desktop-window-unavailable")
                try:
                    if _conversation_is_current(ax, windows, title):
                        break
                finally:
                    for window in windows:
                        ax.release(window)
                if time.monotonic() >= navigation_deadline:
                    raise ChatTranscriptUnavailable("conversation-row-not-actionable")
            # The sidebar selection flips just before the transcript subtree is
            # replaced. Give the renderer one short turn, then reacquire it.
            time.sleep(0.25)

        deadline = time.monotonic() + TRANSCRIPT_LOAD_TIMEOUT_SECONDS
        while True:
            time.sleep(0.15)
            windows = _desktop_windows(ax)
            if not windows:
                raise ChatTranscriptUnavailable("desktop-window-unavailable")
            try:
                markers = ax.find(windows, lambda element: _message_role(ax, element) is not None)
                try:
                    if markers:
                        messages = [_message_from_marker(ax, marker) for marker in markers]
                        messages = [message for message in messages if message.segments]
                        if not messages:
                            raise ChatTranscriptUnavailable("desktop-transcript-unavailable")
                        activity = "streaming" if _has_streaming_button(ax, windows) else "idle"
                        is_partial = _has_loading_older_marker(ax, windows)
                        return _render_messages(messages, activity, is_partial)
                finally:
                    for marker in markers:
                        ax.release(marker)
            finally:
                for window in windows:
                    ax.release(window)
            if time.monotonic() >= deadline:
                raise ChatTranscriptUnavailable("desktop-transcript-unavailable")
    finally:
        ax.close()


def _wait_for_desktop_window(ax: _MacAccessibility) -> None:
    deadline = time.monotonic() + DESKTOP_WINDOW_LOAD_TIMEOUT_SECONDS
    while True:
        windows = _desktop_windows(ax)
        try:
            if windows:
                return
        finally:
            for window in windows:
                ax.release(window)
        if time.monotonic() >= deadline:
            raise ChatTranscriptUnavailable("desktop-window-unavailable")
        time.sleep(0.15)


def _desktop_windows(ax: _MacAccessibility) -> list[int]:
    """Return only real Desktop windows, not Chromium's windowless AX shell.

    A running ChatGPT process can remain alive after its last window disappears.
    In that state recent Chromium builds can return the AXApplication itself in
    AXWindows, creating a self-referential tree that looks non-empty but never
    exposes renderer content. Treat that as windowless instead of waiting for a
    transcript that cannot arrive.
    """
    windows = ax.windows()
    real: list[int] = []
    try:
        for window in windows:
            if ax.text_attribute(window, "AXRole") == "AXWindow":
                real.append(ax.retain(window))
        return real
    finally:
        for window in windows:
            ax.release(window)


def _request_web_accessibility(pid: int) -> str:
    try:
        completed = subprocess.run(
            ["/usr/bin/osascript", "-", str(pid)],
            input=_ENABLE_WEB_ACCESSIBILITY_SCRIPT,
            text=True,
            capture_output=True,
            timeout=4,
        )
    except subprocess.TimeoutExpired as error:
        raise ChatTranscriptUnavailable("desktop-accessibility-timeout") from error
    if completed.returncode != 0:
        raise ChatTranscriptUnavailable("desktop-accessibility-permission-required")
    return completed.stdout.strip()


def _ensure_web_accessibility(ax: _MacAccessibility, pid: int) -> None:
    # Chromium on macOS does not necessarily build its renderer accessibility
    # tree until a client first asks the application for its accessibility role.
    # Do this before requesting the enhanced UI mode used by screen readers.
    ax.text_attribute(ax.app, "AXRole")

    deadline = time.monotonic() + WEB_ACCESSIBILITY_LOAD_TIMEOUT_SECONDS
    if _web_content_is_exposed(ax):
        return

    while True:
        reason = _request_web_accessibility(pid)
        if reason == "desktop-process-unavailable":
            raise ChatTranscriptUnavailable(reason)
        if reason not in {"ok", "desktop-accessibility-not-ready"}:
            raise ChatTranscriptUnavailable("desktop-accessibility-failed")
        if reason == "ok":
            break
        if time.monotonic() >= deadline:
            raise ChatTranscriptUnavailable("desktop-accessibility-timeout")
        time.sleep(0.25)

    while not _web_content_is_exposed(ax):
        if time.monotonic() >= deadline:
            raise ChatTranscriptUnavailable("desktop-accessibility-timeout")
        time.sleep(0.15)


def _web_content_is_exposed(ax: _MacAccessibility) -> bool:
    windows = _desktop_windows(ax)
    if not windows:
        raise ChatTranscriptUnavailable("desktop-window-unavailable")
    try:
        matches = ax.find(
            windows,
            lambda element: (
                ax.text_attribute(element, "AXRole") == "AXButton"
                and bool(ax.text_attribute(element, "AXTitle"))
            ),
        )
        try:
            return bool(matches)
        finally:
            for match in matches:
                ax.release(match)
    finally:
        for window in windows:
            ax.release(window)


def _conversation_button(
    ax: _MacAccessibility,
    windows: list[int],
    title: str,
    project_name: str,
) -> int:
    if project_name:
        list_title = f"Chats in {project_name}"
        lists = ax.find(
            windows,
            lambda element: (
                ax.text_attribute(element, "AXRole") == "AXList"
                and ax.text_attribute(element, "AXTitle") == list_title
            ),
        )
        if not lists:
            project_buttons = ax.find(
                windows,
                lambda element: (
                    ax.text_attribute(element, "AXRole") == "AXButton"
                    and ax.text_attribute(element, "AXTitle") == project_name
                ),
            )
            try:
                if len(project_buttons) == 1:
                    ax.click(project_buttons[0])
                    time.sleep(0.5)
            finally:
                for button in project_buttons:
                    ax.release(button)
            lists = ax.find(
                windows,
                lambda element: (
                    ax.text_attribute(element, "AXRole") == "AXList"
                    and ax.text_attribute(element, "AXTitle") == list_title
                ),
            )
        try:
            candidates: list[int] = []
            for root in lists:
                candidates.extend(
                    ax.find(
                        [root],
                        lambda element: (
                            ax.text_attribute(element, "AXRole") == "AXButton"
                            and _title_matches(ax.text_attribute(element, "AXTitle"), title)
                        ),
                    )
                )
        finally:
            for root in lists:
                ax.release(root)
    else:
        list_roots = ax.find(
            windows,
            lambda element: ax.text_attribute(element, "AXRole") == "AXList",
        )
        try:
            candidates = []
            for root in list_roots:
                candidates.extend(
                    ax.find(
                        [root],
                        lambda element: (
                            ax.text_attribute(element, "AXRole") == "AXButton"
                            and _title_matches(ax.text_attribute(element, "AXTitle"), title)
                        ),
                    )
                )
        finally:
            for root in list_roots:
                ax.release(root)
        if not candidates:
            candidates = ax.find(
                windows,
                lambda element: (
                    ax.text_attribute(element, "AXRole") == "AXButton"
                    and _title_matches(ax.text_attribute(element, "AXTitle"), title)
                ),
            )

    if not candidates:
        raise ChatTranscriptUnavailable("conversation-row-unavailable")
    if len(candidates) > 1:
        for candidate in candidates:
            ax.release(candidate)
        raise ChatTranscriptUnavailable("conversation-row-ambiguous")
    return candidates[0]


def _conversation_is_current(
    ax: _MacAccessibility,
    windows: list[int],
    title: str,
) -> bool:
    web_areas = ax.find(
        windows,
        lambda element: (
            ax.text_attribute(element, "AXRole") == "AXWebArea"
            and _title_matches(ax.text_attribute(element, "AXTitle"), title)
        ),
    )
    try:
        if web_areas:
            return True
    finally:
        for web_area in web_areas:
            ax.release(web_area)
    matches = ax.find(
        windows,
        lambda element: (
            ax.text_attribute(element, "AXRole") == "AXButton"
            and _title_matches(ax.text_attribute(element, "AXTitle"), title)
            and ax.text_attribute(element, "AXARIACurrent") == "page"
        ),
    )
    try:
        return bool(matches)
    finally:
        for match in matches:
            ax.release(match)


def _message_role(ax: _MacAccessibility, element: int) -> str | None:
    if ax.text_attribute(element, "AXRole") != "AXHeading":
        return None
    title = ax.text_attribute(element, "AXTitle")
    if title == "You said:":
        return "user"
    if title == "ChatGPT said:":
        return "assistant"
    return None


def _message_from_marker(ax: _MacAccessibility, marker: int) -> _Message:
    role = _message_role(ax, marker)
    if role is None:
        return _Message("assistant", [])
    parent = ax.element_attribute(marker, "AXParent")
    if parent is None:
        return _Message(role, [])
    segments: list[str] = []
    character_count = 0

    def collect(element: int) -> None:
        nonlocal character_count
        element_role = ax.text_attribute(element, "AXRole")
        if element_role not in {"AXStaticText", "AXHeading", "AXTextArea"}:
            return
        value = _element_text(ax, element)
        if not value or value in {"You said:", "ChatGPT said:", "Loading older messages…"}:
            return
        if re.fullmatch(r"Worked for\s+.+", value):
            return
        character_count += len(value)
        if character_count > MAX_ACCESSIBILITY_CHARACTERS:
            raise ChatTranscriptUnavailable("desktop-accessibility-output-too-large")
        segments.append(value)

    siblings = ax.children(parent)
    try:
        marker_index = next(
            (index for index, sibling in enumerate(siblings) if ax.equal(sibling, marker)),
            None,
        )
        if marker_index is None:
            return _Message(role, [])
        for sibling in siblings[marker_index + 1:]:
            if _message_role(ax, sibling) is not None:
                break
            ax.visit(sibling, collect)
    finally:
        for sibling in siblings:
            ax.release(sibling)
        ax.release(parent)
    return _Message(role, _clean_segments(segments))


def _element_text(ax: _MacAccessibility, element: int) -> str:
    for attribute in ("AXValue", "AXTitle", "AXDescription"):
        value = ax.text_attribute(element, attribute).strip("\x00")
        if value and value != "missing value":
            return value
    return ""


def _has_streaming_button(ax: _MacAccessibility, windows: list[int]) -> bool:
    stop_titles = {"Stop generating", "Stop response", "Stop", "Interrupt", "Cancel response"}
    matches = ax.find(
        windows,
        lambda element: (
            ax.text_attribute(element, "AXRole") == "AXButton"
            and ax.text_attribute(element, "AXTitle") in stop_titles
        ),
    )
    try:
        return bool(matches)
    finally:
        for match in matches:
            ax.release(match)


def _has_loading_older_marker(ax: _MacAccessibility, windows: list[int]) -> bool:
    matches = ax.find(
        windows,
        lambda element: _element_text(ax, element) == "Loading older messages…",
    )
    try:
        return bool(matches)
    finally:
        for match in matches:
            ax.release(match)


def _render_messages(messages: list[_Message], activity: str, is_partial: bool) -> dict[str, Any]:
    rendered: list[dict[str, Any]] = []
    total_characters = 0
    for message in messages:
        text = _merge_segments(message.segments)
        if len(text) > MAX_MESSAGE_CHARACTERS:
            raise ChatTranscriptUnavailable("desktop-accessibility-output-too-large")
        total_characters += len(text)
        if total_characters > MAX_ACCESSIBILITY_CHARACTERS:
            raise ChatTranscriptUnavailable("desktop-accessibility-output-too-large")
        rendered.append({"role": message.role, "text": text, "segments": message.segments})
    return {
        "messages": rendered,
        "activity": activity,
        "isPartial": is_partial,
        "messageCount": len(rendered),
    }


def _title_matches(candidate: str, target: str) -> bool:
    if candidate == target:
        return True
    if candidate.endswith("…") and target.startswith(candidate[:-1]):
        return True
    if target.endswith("…") and candidate.startswith(target[:-1]):
        return True
    return False


def _clean_segments(values: list[str]) -> list[str]:
    result: list[str] = []
    for value in values:
        if not value:
            continue
        if result and result[-1] == value:
            continue
        result.append(value)
    return result


def _merge_segments(values: list[str]) -> str:
    output = ""
    for value in values:
        if not output:
            output = value
            continue
        if output[-1:].isspace() or value[:1].isspace():
            output += value
            continue
        if output.endswith(("\n", "•", "-")):
            output += value
            continue
        if output.endswith((".", "!", "?", ":", "。", "다.", "요.")) and len(value) > 8:
            output += "\n\n" + value
            continue
        output += value
    return output
