from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import subprocess
from typing import Protocol
from urllib.parse import urlsplit


SESSION_STATES = {"ready", "available", "restart-required", "unsupported", "unavailable"}


@dataclass(frozen=True)
class Target:
    id: str
    display_name: str
    state: str
    shared_app_server_supported: bool
    session_state: str
    role: str | None = None
    renderer_cdp_supported: bool = False
    renderer_cdp_state: str | None = None

    @property
    def route_key(self) -> str:
        return hashlib.sha256(self.id.encode("utf-8")).hexdigest()[:20]


@dataclass(frozen=True)
class SharedSession:
    target_id: str
    endpoint: str
    desktop_process_id: int | None = None
    renderer_cdp_endpoint: str | None = None


class TargetRuntime(Protocol):
    """Cardinality-agnostic runtime contract consumed by Plura.

    The current adapter is PluraDesktopClient, but Plura's host/catalog/
    renderer layers intentionally depend on this narrow contract so a future
    bundled single-profile provider can satisfy the same lifecycle semantics
    without forking the product code path.
    """

    def targets(self, *, refresh: bool = False) -> list[Target]: ...
    def cached_session(self, target: Target) -> SharedSession | None: ...
    def session(self, target: Target, *, refresh: bool = False) -> SharedSession | None: ...
    def activation_state(self, target: Target) -> str: ...
    def renderer_state(self, target: Target) -> str: ...
    def activate(self, target: Target, *, request_renderer_cdp: bool = False) -> SharedSession: ...
    def prepare_chat(self, target: Target, *, allow_relaunch: bool = False) -> SharedSession: ...


class PluraDesktopClient:
    """TargetRuntime adapter for the installed Plura Desktop contract.

    Plura Desktop owns the app-server/Desktop lifecycle. This host only asks it
    to launch a target and obtains the loopback endpoint for an already canonical
    session; it never creates a second supervisor or fallback writer.
    """

    def __init__(self, control_cli: Path) -> None:
        self.control_cli = control_cli
        self._targets_cache: list[Target] | None = None
        self._session_cache: dict[str, SharedSession] = {}

    def _run_json(self, *arguments: str) -> dict[str, object]:
        if not self.control_cli.is_file():
            raise RuntimeError(f"Plura Desktop control CLI is missing: {self.control_cli}")
        result = subprocess.run(
            [str(self.control_cli), *arguments],
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            message = result.stderr.strip() or result.stdout.strip() or "Plura Desktop command failed"
            raise RuntimeError(message)
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError("Plura Desktop returned invalid JSON") from error
        if not isinstance(payload, dict):
            raise RuntimeError("Plura Desktop returned a non-object contract")
        return payload

    def targets(self, *, refresh: bool = False) -> list[Target]:
        if not refresh and self._targets_cache is not None:
            return list(self._targets_cache)
        payload = self._run_json("targets", "--json")
        if payload.get("contractVersion") != 1 or not isinstance(payload.get("targets"), list):
            raise RuntimeError("Unsupported Plura Desktop target contract")
        targets: list[Target] = []
        seen: set[str] = set()
        for raw in payload["targets"]:
            if not isinstance(raw, dict):
                continue
            target_id = raw.get("id")
            display = raw.get("displayName")
            state = raw.get("state")
            session_state = raw.get("sessionState")
            if not all(isinstance(value, str) and value for value in (target_id, display, state, session_state)):
                continue
            if session_state not in SESSION_STATES:
                raise RuntimeError("Plura Desktop target contract contains an unknown session state")
            if target_id in seen:
                raise RuntimeError("Plura Desktop target contract contains duplicate IDs")
            seen.add(target_id)
            targets.append(
                Target(
                    id=target_id,
                    display_name=display,
                    state=state,
                    shared_app_server_supported=raw.get("sharedAppServerSupported") is True,
                    session_state=session_state,
                    role=(raw.get("role") if isinstance(raw.get("role"), str) and raw.get("role") else None),
                    renderer_cdp_supported=raw.get("rendererCDPSupported") is True,
                    renderer_cdp_state=(
                        raw.get("rendererCDPState")
                        if isinstance(raw.get("rendererCDPState"), str)
                        and raw.get("rendererCDPState") in SESSION_STATES
                        else None
                    ),
                )
            )
        self._targets_cache = list(targets)
        if refresh:
            # A target can keep the same public state while its canonical
            # supervisor restarts onto a new loopback endpoint. A deliberate
            # target refresh therefore invalidates endpoint snapshots too.
            self._session_cache.clear()
        return targets

    def cached_session(self, target: Target) -> SharedSession | None:
        return self._session_cache.get(target.id)

    def session(self, target: Target, *, refresh: bool = False) -> SharedSession | None:
        if not refresh:
            cached = self._session_cache.get(target.id)
            if cached is not None:
                return cached
        payload = self._run_json("target-session", "--target", target.id, "--json")
        if payload.get("contractVersion") != 1 or payload.get("targetID") != target.id:
            raise RuntimeError("Unsupported Plura Desktop session contract")
        if payload.get("state") != "ready":
            self._session_cache.pop(target.id, None)
            return None
        endpoint = payload.get("endpoint")
        if not isinstance(endpoint, str) or not endpoint.startswith("ws://127.0.0.1:"):
            raise RuntimeError("Plura Desktop returned an invalid canonical endpoint")
        raw_pid = payload.get("desktopProcessID")
        if raw_pid is not None and (not isinstance(raw_pid, int) or isinstance(raw_pid, bool) or raw_pid <= 0):
            raise RuntimeError("Plura Desktop returned an invalid desktop process identifier")
        renderer_cdp_endpoint = payload.get("rendererCDPEndpoint")
        if renderer_cdp_endpoint is not None:
            if not isinstance(renderer_cdp_endpoint, str):
                raise RuntimeError("Plura Desktop returned an invalid renderer CDP endpoint")
            parsed_cdp = urlsplit(renderer_cdp_endpoint)
            if (
                parsed_cdp.scheme != "http"
                or parsed_cdp.hostname not in {"127.0.0.1", "localhost", "::1"}
                or parsed_cdp.port is None
                or parsed_cdp.path not in {"", "/"}
                or parsed_cdp.query
                or parsed_cdp.fragment
            ):
                raise RuntimeError("Plura Desktop returned an invalid renderer CDP endpoint")
        session = SharedSession(target.id, endpoint, raw_pid, renderer_cdp_endpoint)
        self._session_cache[target.id] = session
        return session

    def activation_state(self, target: Target) -> str:
        return target.session_state

    def renderer_state(self, target: Target) -> str:
        if target.renderer_cdp_state in SESSION_STATES:
            return target.renderer_cdp_state
        session = self.cached_session(target)
        if session is not None:
            return "ready" if session.renderer_cdp_endpoint is not None else "restart-required"
        return target.session_state

    def activate(self, target: Target, *, request_renderer_cdp: bool = False) -> SharedSession:
        if target.session_state == "ready":
            session = self.session(target)
            if session is None:
                raise RuntimeError("unavailable")
            if request_renderer_cdp and session.renderer_cdp_endpoint is None:
                raise RuntimeError("renderer-cdp-restart-required")
            return session
        if target.session_state != "available":
            raise RuntimeError(target.session_state)
        command = [str(self.control_cli), "launch-target", "--target", target.id]
        if request_renderer_cdp:
            command.append("--renderer-cdp")
        result = subprocess.run(
            command,
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            message = result.stderr.strip() or result.stdout.strip() or "canonical-runtime-launch-failed"
            raise RuntimeError(message)
        session = self.session(target, refresh=True)
        if session is None:
            raise RuntimeError("canonical-runtime-not-ready")
        return session

    def prepare_chat(self, target: Target, *, allow_relaunch: bool = False) -> SharedSession:
        """Ensure the target has Plura Desktop's best available Chat follower capability.

        The public Plura Mobile contract intentionally asks for "Chat preparation"
        rather than renderer CDP. Renderer CDP is today's Plura Desktop adapter
        implementation detail and can be replaced later without changing the
        mobile/host contract.

        Relaunch is never implicit. A caller must explicitly opt in after a
        user-facing confirmation because a normal Desktop quit can interrupt an
        unsent draft or in-progress response.
        """
        state = self.renderer_state(target)
        if state == "ready":
            session = self.session(target, refresh=True)
            if session is None or session.renderer_cdp_endpoint is None:
                raise RuntimeError("chat-mirror-unavailable")
            return session
        if state == "available":
            return self.activate(target, request_renderer_cdp=True)
        if state == "restart-required":
            if not allow_relaunch:
                raise RuntimeError("chat-relaunch-required")
            self._run_json("quit-target", "--target", target.id, "--json")
            refreshed = next(
                (candidate for candidate in self.targets(refresh=True) if candidate.id == target.id),
                None,
            )
            if refreshed is None:
                raise RuntimeError("target-disappeared")
            return self.activate(refreshed, request_renderer_cdp=True)
        if state in {"unsupported", "unavailable"}:
            raise RuntimeError(state)
        raise RuntimeError("chat-mirror-unavailable")
