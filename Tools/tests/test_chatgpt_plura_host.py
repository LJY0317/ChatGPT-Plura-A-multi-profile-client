from __future__ import annotations

import asyncio
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

from chatgpt_plura_host.bridge import BridgeServer, PairingState
from chatgpt_plura_host.attachments import ChatAttachmentStore
from chatgpt_plura_host.catalog import _read_catalog
from chatgpt_plura_host.plura_desktop import PluraDesktopClient, SharedSession, Target
from chatgpt_plura_host.network import (
    ConnectionEndpoint,
    _tailscale_endpoints_from_status,
    _zerotier_endpoints_from_networks,
)
import chatgpt_plura_host.platform as host_platform
from chatgpt_plura_host.platform import _linux_lan_ipv4_from_ip, _macos_lan_ipv4_from_ifconfig
from chatgpt_plura_host.renderer import (
    ChatRendererUnavailable,
    ChatTranscriptUnavailable,
    TargetChatComposerProvider,
    TargetChatTranscriptProvider,
    _attachment_input_expression,
    _attachment_ready_expression,
    _composer_focus_expression,
    _composer_submit_expression,
    _normalize_renderer_transcript_result,
    _normalize_semantic_items,
    _transcript_expression,
)


HOST_CLI_SPEC = importlib.util.spec_from_file_location("plura_host_cli", TOOLS / "chatgpt-plura-host.py")
assert HOST_CLI_SPEC is not None and HOST_CLI_SPEC.loader is not None
HOST_CLI = importlib.util.module_from_spec(HOST_CLI_SPEC)
HOST_CLI_SPEC.loader.exec_module(HOST_CLI)


def write_fake_control(
    root: Path,
    target_payload: dict[str, object],
    *,
    session_payload: dict[str, object] | None = None,
    launch_makes_ready: bool = False,
    normalize_contract: bool = True,
) -> Path:
    target_payload = json.loads(json.dumps(target_payload))
    if normalize_contract:
        raw_targets = target_payload.get("targets")
        if isinstance(raw_targets, list):
            for index, item in enumerate(raw_targets):
                if not isinstance(item, dict):
                    continue
                target_id = item.get("id")
                session_state = item.get("sessionState", "unavailable")
                item.setdefault("role", "default" if target_id == "default" else "managed")
                item.setdefault("managed", target_id != "default")
                item.setdefault("ownership", "official-desktop-profile")
                item.setdefault("backendPolicy", "single-authoritative-profile-runtime")
                item.setdefault("state", "running" if session_state in {"ready", "restart-required"} else "stopped")
                item.setdefault("sharedAppServerSupported", session_state != "unsupported")
                item.setdefault("responsesRouteSupported", session_state != "unsupported")
                item.setdefault("rendererCDPSupported", True)
                item.setdefault(
                    "rendererCDPState",
                    "restart-required" if session_state == "ready" else session_state,
                )
    script = root / "fake-control.py"
    first_target = target_payload["targets"][0]  # type: ignore[index]
    target_id = first_target["id"]  # type: ignore[index]
    initial_session = dict(session_payload or {
        "contractVersion": 1,
        "targetID": target_id,
        "state": first_target.get("sessionState", "unavailable"),  # type: ignore[union-attr]
    })
    if "rendererCDPState" not in initial_session:
        initial_session["rendererCDPState"] = (
            "ready"
            if initial_session.get("rendererCDPEndpoint") is not None
            else (
                "restart-required"
                if initial_session.get("state") == "ready"
                else first_target.get("rendererCDPState", "unavailable")  # type: ignore[union-attr]
            )
        )
    ready_session = {
        "contractVersion": 1,
        "targetID": target_id,
        "state": "ready",
        "endpoint": "ws://127.0.0.1:19444",
        "rendererCDPState": "restart-required",
    }
    ready_renderer_session = {
        **ready_session,
        "rendererCDPState": "ready",
        "rendererCDPEndpoint": "http://127.0.0.1:19222",
    }
    script.write_text(
        "import json, pathlib, sys\n"
        + f"targets={target_payload!r}\n"
        + f"initial={initial_session!r}\n"
        + f"ready={ready_session!r}\n"
        + f"ready_renderer={ready_renderer_session!r}\n"
        + f"flag=pathlib.Path({str(root / 'ready.flag')!r})\n"
        + f"launch_makes_ready={launch_makes_ready!r}\n"
        + "command=sys.argv[1]\n"
        + "if command == 'targets': print(json.dumps(targets))\n"
        + "elif command == 'target-session':\n"
        + "    if launch_makes_ready and flag.exists(): print(json.dumps(ready_renderer if flag.read_text() == 'renderer' else ready))\n"
        + "    else: print(json.dumps(initial))\n"
        + "elif command == 'launch-target':\n"
        + f"    pathlib.Path({str(root / 'launch-args.json')!r}).write_text(json.dumps(sys.argv[2:]))\n"
        + "    if launch_makes_ready: flag.write_text('renderer' if '--renderer-cdp' in sys.argv else 'ready')\n"
        + "    print(json.dumps((ready_renderer if '--renderer-cdp' in sys.argv else ready) if launch_makes_ready else initial))\n"
        + "else: raise SystemExit(2)\n",
        encoding="utf-8",
    )
    if os.name == "nt":
        wrapper = root / "plura-desktop.cmd"
        wrapper.write_text(
            f'@echo off\r\n"{sys.executable}" "{script}" %*\r\n',
            encoding="utf-8",
        )
    else:
        wrapper = root / "plura-desktop"
        wrapper.write_text(
            f"#!/bin/sh\nexec {json.dumps(sys.executable)} {json.dumps(str(script))} \"$@\"\n",
            encoding="utf-8",
        )
        wrapper.chmod(0o700)
    return wrapper


class FakeMultiProfile:
    def __init__(self, targets: list[Target]) -> None:
        self._targets = targets

    def targets(self, *, refresh: bool = False) -> list[Target]:
        return list(self._targets)

    def activation_state(self, target: Target) -> str:
        return target.session_state

    def renderer_state(self, target: Target) -> str:
        return target.renderer_cdp_state

    def session(self, target: Target) -> SharedSession | None:
        return None

    def cached_session(self, target: Target) -> SharedSession | None:
        return None

    def activate(self, target: Target, *, request_renderer_cdp: bool = False) -> SharedSession:
        raise RuntimeError(target.session_state)

    def prepare_chat(self, target: Target, *, allow_relaunch: bool = False) -> SharedSession:
        raise RuntimeError(self.renderer_state(target))


class HostContractTests(unittest.TestCase):
    def test_platforms_use_only_canonical_plura_desktop_control_cli(self):
        dummy_store = object()
        with (
            patch.object(host_platform.Path, "home", return_value=Path("/Users/tester")),
            patch.object(host_platform.sys, "platform", "darwin"),
            patch.object(host_platform, "MacOSCredentialStore", return_value=dummy_store),
        ):
            platform = host_platform.current_platform()
            self.assertEqual(
                platform.control_cli,
                Path("/Users/tester/Library/Application Support/PluraDesktop/plura-desktop"),
            )

        with (
            patch.object(host_platform.Path, "home", return_value=Path("C:/Users/tester")),
            patch.object(host_platform.sys, "platform", "win32"),
            patch.dict(host_platform.os.environ, {"LOCALAPPDATA": "C:/Users/tester/AppData/Local"}, clear=False),
            patch.object(host_platform, "WindowsCredentialStore", return_value=dummy_store),
        ):
            platform = host_platform.current_platform()
            self.assertEqual(
                platform.control_cli,
                Path("C:/Users/tester/AppData/Local/PluraDesktop/plura-desktop.cmd"),
            )

        with (
            patch.object(host_platform.Path, "home", return_value=Path("/home/tester")),
            patch.object(host_platform.sys, "platform", "linux"),
            patch.dict(host_platform.os.environ, {"XDG_STATE_HOME": "/home/tester/.local/state"}, clear=False),
            patch.object(host_platform, "LinuxCredentialStore", return_value=dummy_store),
        ):
            platform = host_platform.current_platform()
            self.assertEqual(
                platform.control_cli,
                Path("/home/tester/.local/state/PluraDesktop/plura-desktop"),
            )

    def test_show_pairing_is_one_shot_and_does_not_start_server(self):
        class CredentialStore:
            def load_or_create(self, *, reset: bool = False):
                return ("capability-token", False)

        class Platform:
            def __init__(self, root: Path) -> None:
                self.state_dir = root / "state"
                self.credential_store = CredentialStore()

        args = argparse.Namespace(
            listen_host="0.0.0.0",
            listen_port=8765,
            show_pairing=True,
            reset_pairing=False,
            pairing_bootstrap_file=None,
            advertise_endpoint=[],
        )
        with tempfile.TemporaryDirectory() as temp:
            platform = Platform(Path(temp))
            output = io.StringIO()
            with (
                patch.object(HOST_CLI, "current_platform", return_value=platform),
                patch.object(HOST_CLI, "discover_connection_endpoints", return_value=[]),
                patch.object(HOST_CLI.asyncio, "start_server", side_effect=AssertionError("must not bind")),
                contextlib.redirect_stdout(output),
            ):
                asyncio.run(HOST_CLI.run(args))

        self.assertIn("Plura Host pairing", output.getvalue())
        self.assertIn("Pairing token (enter once): capability-token", output.getvalue())

    def test_tailscale_status_prefers_stable_dns_then_ips(self):
        endpoints = _tailscale_endpoints_from_status(
            json.dumps({
                "Self": {
                    "DNSName": "my-mac.example.ts.net.",
                    "TailscaleIPs": ["100.64.12.34", "fd7a:115c:a1e0::1234"],
                }
            }),
            8765,
        )
        self.assertEqual(endpoints[0].url, "ws://my-mac.example.ts.net:8765")
        self.assertEqual(endpoints[0].kind, "tailscale")
        self.assertIn("ws://100.64.12.34:8765", [item.url for item in endpoints])

    def test_zerotier_networks_emit_only_ok_assigned_addresses(self):
        endpoints = _zerotier_endpoints_from_networks(
            json.dumps([
                {"status": "OK", "assignedAddresses": ["10.42.17.1/24", "fd00::1/64"]},
                {"status": "ACCESS_DENIED", "assignedAddresses": ["10.99.0.2/24"]},
            ]),
            8765,
        )
        self.assertEqual([item.kind for item in endpoints], ["zerotier", "zerotier"])
        self.assertIn("ws://10.42.17.1:8765", [item.url for item in endpoints])
        self.assertNotIn("ws://10.99.0.2:8765", [item.url for item in endpoints])

    def test_macos_lan_address_ignores_vpn_tunnel(self):
        output = """\
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
\tinet 10.254.0.4 --> 10.254.0.4 netmask 0xffff0000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.50.42 netmask 0xffffff00 broadcast 192.168.50.255
\tstatus: active
"""
        self.assertEqual(_macos_lan_ipv4_from_ifconfig(output), "192.168.50.42")

    def test_linux_lan_address_ignores_virtual_interfaces(self):
        output = """\
7: tailscale0    inet 100.64.0.1/32 scope global tailscale0
2: eth0    inet 192.168.77.20/24 brd 192.168.77.255 scope global eth0
"""
        self.assertEqual(_linux_lan_ipv4_from_ip(output), "192.168.77.20")

    def test_route_keys_are_target_derived_and_not_profile_slots(self):
        targets = [
            Target("default", "ChatGPT", "restart-required", "restart-required", "default"),
            Target("local.example.work", "Work", "available", "available", "managed"),
            Target("local.example.third", "Third", "available", "available", "managed"),
        ]
        keys = [target.route_key for target in targets]
        self.assertEqual(len(set(keys)), 3)
        self.assertTrue(all(len(key) == 20 for key in keys))
        rendered = json.dumps(keys)
        self.assertNotIn("profile1", rendered)
        self.assertNotIn("profile2", rendered)

    def test_running_private_target_requires_restart_and_never_activates_fallback(self):
        target = Target("default", "ChatGPT", "restart-required", "restart-required", "default")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [
                        {
                            "id": "default",
                            "displayName": "ChatGPT",
                            "role": "default",
                            "state": "running",
                            "sharedAppServerSupported": True,
                            "sessionState": "restart-required",
                        }
                    ],
                },
            )
            client = PluraDesktopClient(cli)
            discovered = client.targets()[0]
            self.assertEqual(discovered.role, "default")
            self.assertEqual(client.activation_state(discovered), "restart-required")
            with self.assertRaisesRegex(RuntimeError, "restart-required"):
                client.activate(discovered)
            self.assertFalse((root / "ready.flag").exists())

    def test_target_contract_is_dynamic_and_contains_no_private_profile_paths(self):
        targets = [
            Target("default", "ChatGPT", "restart-required", "restart-required", "default"),
            Target("team-alpha", "Team Alpha", "available", "available", "managed"),
        ]
        bridge = BridgeServer(
            FakeMultiProfile(targets),
            "secret",
            None,
        )
        payload = json.loads(bridge._targets_payload())
        self.assertEqual(payload["contractVersion"], 1)
        self.assertEqual([item["displayName"] for item in payload["targets"]], ["ChatGPT", "Team Alpha"])
        self.assertEqual([item["role"] for item in payload["targets"]], ["default", "managed"])
        self.assertEqual(
            [item["chatMirrorState"] for item in payload["targets"]],
            ["restart-required", "available"],
        )
        self.assertTrue(all("rendererCDPState" not in item for item in payload["targets"]))
        rendered = json.dumps(payload)
        self.assertNotIn("CODEX_HOME", rendered)
        self.assertNotIn(".codex", rendered)
        self.assertNotIn("8766", rendered)
        self.assertNotIn("8767", rendered)

    def test_target_contract_requires_renderer_state(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [{
                        "id": "target",
                        "displayName": "Target",
                        "role": "managed",
                        "ownership": "official-desktop-profile",
                        "backendPolicy": "single-authoritative-profile-runtime",
                        "state": "stopped",
                        "sharedAppServerSupported": True,
                        "responsesRouteSupported": True,
                        "rendererCDPSupported": True,
                        "sessionState": "available",
                    }],
                },
                normalize_contract=False,
            )
            with self.assertRaisesRegex(RuntimeError, "missing required target fields"):
                PluraDesktopClient(cli).targets()

    def test_target_contract_rejects_unknown_ownership_policy(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [{
                        "id": "target",
                        "displayName": "Target",
                        "role": "managed",
                        "ownership": "legacy-profile-owner",
                        "backendPolicy": "single-authoritative-profile-runtime",
                        "state": "stopped",
                        "sharedAppServerSupported": True,
                        "responsesRouteSupported": True,
                        "rendererCDPSupported": True,
                        "sessionState": "available",
                        "rendererCDPState": "available",
                    }],
                },
                normalize_contract=False,
            )
            with self.assertRaisesRegex(RuntimeError, "unsupported ownership policy"):
                PluraDesktopClient(cli).targets()

    def test_target_contract_rejects_inconsistent_role_and_managed_flag(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [{
                        "id": "target",
                        "displayName": "Target",
                        "role": "managed",
                        "managed": False,
                        "ownership": "official-desktop-profile",
                        "backendPolicy": "single-authoritative-profile-runtime",
                        "state": "stopped",
                        "sharedAppServerSupported": True,
                        "responsesRouteSupported": True,
                        "rendererCDPSupported": True,
                        "sessionState": "available",
                        "rendererCDPState": "available",
                    }],
                },
                normalize_contract=False,
            )
            with self.assertRaisesRegex(RuntimeError, "inconsistent target ownership"):
                PluraDesktopClient(cli).targets()

    def test_target_contract_rejects_inconsistent_renderer_capability_state(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [{
                        "id": "target",
                        "displayName": "Target",
                        "role": "managed",
                        "managed": True,
                        "ownership": "official-desktop-profile",
                        "backendPolicy": "single-authoritative-profile-runtime",
                        "state": "stopped",
                        "sharedAppServerSupported": True,
                        "responsesRouteSupported": True,
                        "rendererCDPSupported": False,
                        "sessionState": "available",
                        "rendererCDPState": "available",
                    }],
                },
                normalize_contract=False,
            )
            with self.assertRaisesRegex(RuntimeError, "inconsistent renderer capability state"):
                PluraDesktopClient(cli).targets()

    def test_ready_session_is_read_from_plura_desktop_contract(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [{
                        "id": "target",
                        "displayName": "Target",
                        "state": "running",
                        "sharedAppServerSupported": True,
                        "sessionState": "ready",
                    }],
                },
                session_payload={
                    "contractVersion": 1,
                    "targetID": "target",
                    "state": "ready",
                    "endpoint": "ws://127.0.0.1:19443",
                },
            )
            client = PluraDesktopClient(cli)
            target = client.targets()[0]
            self.assertEqual(client.session(target), SharedSession("target", "ws://127.0.0.1:19443"))

    def test_target_and_session_hot_paths_reuse_canonical_snapshots_until_refresh(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [{
                        "id": "target",
                        "displayName": "Target",
                        "state": "running",
                        "sharedAppServerSupported": True,
                        "sessionState": "ready",
                    }],
                },
                session_payload={
                    "contractVersion": 1,
                    "targetID": "target",
                    "state": "ready",
                    "endpoint": "ws://127.0.0.1:19443",
                },
            )
            client = PluraDesktopClient(cli)
            with patch.object(client, "_run_json", wraps=client._run_json) as run_json:
                first_targets = client.targets(refresh=True)
                self.assertEqual(run_json.call_count, 1)
                self.assertEqual(client.targets(), first_targets)
                self.assertEqual(run_json.call_count, 1)

                target = first_targets[0]
                first_session = client.session(target)
                self.assertEqual(run_json.call_count, 2)
                self.assertEqual(client.session(target), first_session)
                self.assertEqual(client.cached_session(target), first_session)
                self.assertEqual(run_json.call_count, 2)

                client.targets(refresh=True)
                self.assertEqual(run_json.call_count, 3)
                self.assertIsNone(client.cached_session(target))

    def test_ready_session_preserves_canonical_desktop_process_id(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [{
                        "id": "target",
                        "displayName": "Target",
                        "state": "running",
                        "sharedAppServerSupported": True,
                        "sessionState": "ready",
                    }],
                },
                session_payload={
                    "contractVersion": 1,
                    "targetID": "target",
                    "state": "ready",
                    "endpoint": "ws://127.0.0.1:19443",
                    "desktopProcessID": 4321,
                },
            )
            client = PluraDesktopClient(cli)
            target = client.targets()[0]
            self.assertEqual(
                client.session(target),
                SharedSession("target", "ws://127.0.0.1:19443", 4321),
            )

    def test_ready_session_preserves_renderer_cdp_endpoint(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [{
                        "id": "target",
                        "displayName": "Target",
                        "state": "running",
                        "sharedAppServerSupported": True,
                        "sessionState": "ready",
                    }],
                },
                session_payload={
                    "contractVersion": 1,
                    "targetID": "target",
                    "state": "ready",
                    "endpoint": "ws://127.0.0.1:19443",
                    "desktopProcessID": 4321,
                    "rendererCDPEndpoint": "http://127.0.0.1:19222",
                },
            )
            client = PluraDesktopClient(cli)
            target = client.targets()[0]
            self.assertEqual(
                client.session(target),
                SharedSession(
                    "target",
                    "ws://127.0.0.1:19443",
                    4321,
                    "http://127.0.0.1:19222",
                ),
            )

    def test_ready_session_rejects_non_loopback_renderer_cdp_endpoint(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [{
                        "id": "target",
                        "displayName": "Target",
                        "state": "running",
                        "sharedAppServerSupported": True,
                        "sessionState": "ready",
                    }],
                },
                session_payload={
                    "contractVersion": 1,
                    "targetID": "target",
                    "state": "ready",
                    "endpoint": "ws://127.0.0.1:19443",
                    "rendererCDPEndpoint": "http://192.0.2.10:9222",
                },
            )
            client = PluraDesktopClient(cli)
            with self.assertRaisesRegex(RuntimeError, "renderer CDP endpoint"):
                client.session(client.targets()[0])

    def test_ready_session_rejects_invalid_desktop_process_id(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [{
                        "id": "target",
                        "displayName": "Target",
                        "state": "running",
                        "sharedAppServerSupported": True,
                        "sessionState": "ready",
                    }],
                },
                session_payload={
                    "contractVersion": 1,
                    "targetID": "target",
                    "state": "ready",
                    "endpoint": "ws://127.0.0.1:19443",
                    "desktopProcessID": "4321",
                },
            )
            client = PluraDesktopClient(cli)
            with self.assertRaisesRegex(RuntimeError, "desktop process identifier"):
                client.session(client.targets()[0])

    def test_host_instances_reattach_through_same_plura_desktop_contract(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [{
                        "id": "target",
                        "displayName": "Target",
                        "state": "running",
                        "sharedAppServerSupported": True,
                        "sessionState": "ready",
                    }],
                },
                session_payload={
                    "contractVersion": 1,
                    "targetID": "target",
                    "state": "ready",
                    "endpoint": "ws://127.0.0.1:19443",
                },
            )
            first_host = PluraDesktopClient(cli)
            second_host = PluraDesktopClient(cli)
            first_target = first_host.targets()[0]
            second_target = second_host.targets()[0]
            first_session = first_host.session(first_target)
            second_session = second_host.session(second_target)
            self.assertEqual(second_session, first_session)
            self.assertEqual(second_host.activation_state(second_target), "ready")

    def test_available_activation_delegates_runtime_ownership_to_plura_desktop(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli = write_fake_control(
                root,
                {
                    "contractVersion": 1,
                    "targets": [{
                        "id": "target",
                        "displayName": "Target",
                        "state": "stopped",
                        "sharedAppServerSupported": True,
                        "sessionState": "available",
                    }],
                },
                launch_makes_ready=True,
            )
            client = PluraDesktopClient(cli)
            target = client.targets()[0]
            session = client.activate(target, request_renderer_cdp=True)
            self.assertEqual(
                session,
                SharedSession(
                    "target",
                    "ws://127.0.0.1:19444",
                    None,
                    "http://127.0.0.1:19222",
                ),
            )
            self.assertTrue((root / "ready.flag").is_file())
            self.assertEqual(
                json.loads((root / "launch-args.json").read_text(encoding="utf-8")),
                ["--target", "target", "--renderer-cdp", "--json"],
            )

    def test_renderer_transcript_provider_prefers_canonical_cdp_session(self):
        target = Target("target", "Target", "ready", "ready", "managed")

        class FakeReadyMultiProfile:
            def session(self, candidate):
                self.assert_target = candidate
                return SharedSession(
                    "target",
                    "ws://127.0.0.1:19444",
                    4321,
                    "http://127.0.0.1:19222",
                )

        calls = []

        def extractor(endpoint, conversation_id, title, project_name):
            calls.append((endpoint, conversation_id, title, project_name))
            return {
                "messages": [{"role": "user", "text": "hello", "segments": ["hello"]}],
                "activity": "idle",
                "isPartial": False,
                "messageCount": 1,
            }

        provider = TargetChatTranscriptProvider(
            FakeReadyMultiProfile(),
            lambda candidate: {
                "entries": [{
                    "id": "conversation",
                    "title": "Project chat",
                    "projectId": "project",
                    "projectName": "Project",
                    "sourceKind": "chatgpt",
                }]
            },
            renderer_extractor=extractor,
        )
        payload = provider(target, "conversation")
        self.assertEqual(payload["source"], "desktop-renderer")
        self.assertEqual(payload["messageCount"], 1)
        self.assertEqual(
            payload["items"],
            [{"kind": "message", "role": "user", "text": "hello", "segments": ["hello"]}],
        )
        self.assertEqual(payload["capabilities"], {"sendText": True, "attachments": False})
        self.assertEqual(
            calls,
            [("http://127.0.0.1:19222", "conversation", "Project chat", "Project")],
        )

    def test_renderer_transcript_provider_requires_canonical_renderer_session(self):
        target = Target("target", "Target", "ready", "restart-required", "managed")

        class FakeReadyMultiProfile:
            def session(self, candidate):
                return SharedSession("target", "ws://127.0.0.1:19444", 4321)

        provider = TargetChatTranscriptProvider(
            FakeReadyMultiProfile(),
            lambda candidate: {"entries": []},
            renderer_extractor=lambda *args: (_ for _ in ()).throw(AssertionError("unexpected renderer call")),
        )
        with self.assertRaisesRegex(ChatTranscriptUnavailable, "desktop-renderer-unavailable"):
            provider(target, "conversation")

    def test_renderer_expression_embeds_values_as_json_not_javascript_source(self):
        expression = _transcript_expression(
            'conversation";throw new Error(1);//',
            'title";alert(1);//',
            'project";location="https://example.com";//',
        )
        self.assertIn('const conversationId = "conversation\\\";throw new Error(1);//";', expression)
        self.assertIn('const expectedTitle = "title\\\";alert(1);//";', expression)
        self.assertIn('const projectName = "project\\\";location=\\\"https://example.com\\\";//";', expression)

    def test_renderer_expression_prefers_semantic_turn_anchors_with_marker_fallback(self):
        expression = _transcript_expression("conversation", "title", "project")
        self.assertIn("[data-user-message-bubble]", expression)
        self.assertIn('[data-conversation-role="assistant"]', expression)
        self.assertIn("semantic-turn-markdown-v2", expression)
        self.assertIn("marker-range-v2", expression)
        self.assertIn("semanticMarkdown", expression)
        self.assertIn("semanticCurrentConversation", expression)
        self.assertIn("location.href.includes(conversationId)", expression)
        self.assertIn("if (!row && !currentByPage) return {status: 'conversation-row-unavailable'};", expression)
        self.assertIn("if (!row) return {status: 'conversation-row-unavailable'};", expression)
        self.assertNotIn("matchesTitle(document.title)", expression)
        self.assertIn("tag === 'pre'", expression)
        self.assertIn("tag === 'table'", expression)
        self.assertIn("You said:", expression)
        self.assertIn("ChatGPT said:", expression)

    def test_renderer_expression_uses_official_semantic_activity_roots_without_label_guessing(self):
        expression = _transcript_expression("conversation", "title", "project")

        self.assertIn("[data-mcp-app-card]", expression)
        self.assertIn("[data-appshot-attachment]", expression)
        self.assertIn("[data-codex-approval-surface]", expression)
        self.assertIn("[data-request-input-activity-root]", expression)
        self.assertIn("kind: 'toolCall'", expression)
        self.assertIn("kind: 'attachment'", expression)
        self.assertIn("kind: 'approval'", expression)
        self.assertIn("kind: 'notice'", expression)
        self.assertNotIn("text === 'Thinking'", expression)
        self.assertNotIn("text === 'Thought'", expression)

    def test_ready_rendererless_target_requires_one_normal_relaunch_when_renderer_requested(self):
        target = Target(
            "default",
            "ChatGPT",
            "ready",
            "restart-required",
            "default",
        )

        class FakeClient(PluraDesktopClient):
            def __init__(self):
                pass

            def session(self, candidate, *, refresh=False):
                return SharedSession(candidate.id, "ws://127.0.0.1:19444", 4321)

        with self.assertRaisesRegex(RuntimeError, "renderer-cdp-restart-required"):
            FakeClient().activate(target, request_renderer_cdp=True)

    def test_chat_prepare_relaunches_only_after_explicit_opt_in(self):
        target = Target(
            "default",
            "ChatGPT",
            "ready",
            "restart-required",
            "default",
        )
        refreshed = Target(
            "default",
            "ChatGPT",
            "available",
            "available",
            "default",
        )

        class FakeClient(PluraDesktopClient):
            def __init__(self):
                self.events = []

            def renderer_state(self, candidate):
                return candidate.renderer_cdp_state

            def _run_json(self, *arguments):
                self.events.append(("command", arguments))
                return {"contractVersion": 1, "targetID": "default", "state": "available"}

            def targets(self, *, refresh=False):
                self.events.append(("targets", refresh))
                return [refreshed]

            def activate(self, candidate, *, request_renderer_cdp=False):
                self.events.append(("activate", candidate.id, request_renderer_cdp))
                return SharedSession(
                    candidate.id,
                    "ws://127.0.0.1:19444",
                    4321,
                    "http://127.0.0.1:19222",
                )

        client = FakeClient()
        with self.assertRaisesRegex(RuntimeError, "chat-relaunch-required"):
            client.prepare_chat(target, allow_relaunch=False)
        self.assertEqual(client.events, [])

        session = client.prepare_chat(target, allow_relaunch=True)
        self.assertEqual(session.renderer_cdp_endpoint, "http://127.0.0.1:19222")
        self.assertEqual(client.events[0][0], "command")
        self.assertEqual(client.events[0][1], ("quit-target", "--target", "default", "--json"))
        self.assertEqual(client.events[1], ("targets", True))
        self.assertEqual(client.events[2], ("activate", "default", True))

    def test_renderer_result_preserves_complete_semantic_timeline(self):
        payload = _normalize_renderer_transcript_result({
            "messages": [
                {"role": "user", "text": "hello"},
                {"role": "assistant", "text": "done"},
            ],
            "items": [
                {"kind": "message", "role": "user", "text": "hello"},
                {
                    "kind": "webSearch",
                    "role": "activity",
                    "text": "OpenAI docs",
                    "title": "Web search",
                    "status": "completed",
                    "durationMs": 1250,
                },
                {"kind": "message", "role": "assistant", "text": "done"},
            ],
            "activity": "idle",
            "isPartial": False,
            "attachmentCapable": True,
        })

        self.assertEqual(payload["messageCount"], 2)
        self.assertEqual(payload["items"][1]["kind"], "webSearch")
        self.assertEqual(payload["items"][1]["durationMs"], 1250)
        self.assertEqual(payload["capabilities"], {"sendText": True, "attachments": True})

    def test_renderer_result_drops_incomplete_semantic_timeline(self):
        payload = _normalize_renderer_transcript_result({
            "messages": [
                {"role": "user", "text": "hello"},
                {"role": "assistant", "text": "done"},
            ],
            "items": [
                {"kind": "webSearch", "role": "activity", "text": "OpenAI docs"},
                {"kind": "message", "role": "assistant", "text": "done"},
            ],
            "activity": "idle",
            "isPartial": False,
        })

        self.assertNotIn("items", payload)
        self.assertEqual(
            payload["messages"],
            [
                {"role": "user", "text": "hello", "segments": ["hello"]},
                {"role": "assistant", "text": "done", "segments": ["done"]},
            ],
        )

    def test_semantic_item_normalizer_preserves_unknown_kind_but_sanitizes_metadata(self):
        payload = _normalize_semantic_items([
            {
                "kind": " future-card ",
                "role": "unexpected-role",
                "text": "visible",
                "sourceId": "x" * 800,
                "title": "Future activity",
                "status": "done",
                "durationMs": 1250,
                "privateFutureField": {"must": "not cross"},
            }
        ])
        self.assertEqual(payload[0]["kind"], "future-card")
        self.assertEqual(payload[0]["text"], "visible")
        self.assertNotIn("role", payload[0])
        self.assertEqual(len(payload[0]["sourceId"]), 512)
        self.assertEqual(payload[0]["durationMs"], 1250)
        self.assertNotIn("privateFutureField", payload[0])

    def test_semantic_item_normalizer_rejects_unbounded_output(self):
        with self.assertRaises(ChatRendererUnavailable):
            _normalize_semantic_items([
                {"kind": "message", "role": "assistant", "text": "x" * (6 * 1024 * 1024 + 1)}
            ])

    def test_renderer_composer_provider_requires_canonical_cdp_and_returns_request_identity(self):
        target = Target("target", "Target", "ready", "ready", "managed")

        class FakeReadyMultiProfile:
            def session(self, candidate, *, refresh=False):
                self.refresh = refresh
                return SharedSession(
                    "target",
                    "ws://127.0.0.1:19444",
                    4321,
                    "http://127.0.0.1:19222",
                )

        calls = []

        def sender(endpoint, conversation_id, title, project_name, text, attachments):
            calls.append((endpoint, conversation_id, title, project_name, text, attachments))
            return {"status": "submitted"}

        provider = TargetChatComposerProvider(
            FakeReadyMultiProfile(),
            lambda candidate: {
                "entries": [{
                    "id": "conversation",
                    "title": "Project chat",
                    "projectId": "project",
                    "projectName": "Project",
                    "sourceKind": "chatgpt",
                }]
            },
            renderer_sender=sender,
        )
        payload = provider(target, "conversation", "  hello  ", "request-1")
        self.assertEqual(payload["clientRequestId"], "request-1")
        self.assertEqual(payload["status"], "submitted")
        self.assertEqual(payload["source"], "desktop-renderer")
        self.assertEqual(
            calls,
            [("http://127.0.0.1:19222", "conversation", "Project chat", "Project", "hello", [])],
        )

    def test_renderer_composer_provider_requires_canonical_renderer_for_write(self):
        target = Target("target", "Target", "ready", "restart-required", "managed")

        class FakeLegacyMultiProfile:
            def session(self, candidate, *, refresh=False):
                return SharedSession("target", "ws://127.0.0.1:19444", 4321)

        provider = TargetChatComposerProvider(
            FakeLegacyMultiProfile(),
            lambda candidate: {"entries": []},
            renderer_sender=lambda *args: (_ for _ in ()).throw(AssertionError("write fallback must not run")),
        )
        with self.assertRaisesRegex(ChatTranscriptUnavailable, "desktop-renderer-unavailable"):
            provider(target, "conversation", "hello", "request-1")

    def test_renderer_composer_expressions_are_json_safe_and_fail_closed(self):
        focus = _composer_focus_expression(
            'conversation";throw new Error(1);//',
            'title";alert(1);//',
            'project";location="https://example.com";//',
            ['photo";alert(2);//.png'],
            ["image/png"],
        )
        submit = _composer_submit_expression(
            'conversation";throw new Error(1);//',
            'hello";document.body.remove();//',
            7,
            ['photo";alert(2);//.png'],
        )
        attachment_input = _attachment_input_expression(
            ['photo";alert(2);//.png'],
            ["image/png"],
        )
        attachment_ready = _attachment_ready_expression(
            ['photo";alert(2);//.png'],
            ["image/png"],
        )
        self.assertIn('const conversationId = "conversation\\\";throw new Error(1);//";', focus)
        self.assertIn("desktop-composer-draft-present", focus)
        self.assertIn("data-composer-attachments", focus)
        self.assertIn("data-visible-attachments", focus)
        self.assertIn("composerHasAnyAttachment", focus)
        self.assertIn("desktop-attachment-input-unavailable", focus)
        self.assertIn("#prompt-textarea", focus)
        self.assertIn("data-sidebar-chatgpt-conversation-key", focus)
        self.assertIn("data-chatgpt-selection-conversation-id", focus)
        self.assertIn("semanticCurrentConversation()", focus)
        self.assertIn("if (!row && !currentByPage) return {status: 'conversation-row-unavailable'};", focus)
        self.assertNotIn("matchesTitle(document.title)", focus)
        self.assertIn('const expectedText = "hello\\\";document.body.remove();//";', submit)
        self.assertIn('photo\\\";alert(2);//.png', attachment_input)
        self.assertIn("data-map-composer-conversation", submit)
        self.assertIn("const isExpectedConversation = () =>", submit)
        self.assertIn("data-composer-attachments", submit)
        self.assertIn("data-visible-attachments", submit)
        self.assertIn("composerShowsExpectedAttachments", submit)
        self.assertIn("fileInputsShowExpectedAttachments", submit)
        self.assertIn("desktop-attachment-changed", attachment_ready)
        self.assertIn("composerHasExpectedAttachments", attachment_ready)
        self.assertIn("fileInputsHaveExpectedAttachments", attachment_ready)
        self.assertIn("conversation-changed-before-submit", submit)
        self.assertIn("desktop-composer-send-unavailable", submit)
        self.assertIn("previousUserMessageCount = 7", submit)

    def test_chat_attachment_store_is_target_scoped_and_expires(self):
        now = [100.0]
        with tempfile.TemporaryDirectory() as temp:
            store = ChatAttachmentStore(Path(temp), now=lambda: now[0])
            item = store.stage("target-a", "../photo.png", "image/png", b"png")
            self.assertEqual(item.filename, "photo.png")
            self.assertEqual(store.resolve_many("target-a", [item.id]), [item])
            with self.assertRaisesRegex(ValueError, "chat-attachment-unavailable"):
                store.resolve_many("target-b", [item.id])

            now[0] += 16 * 60
            with self.assertRaisesRegex(ValueError, "chat-attachment-unavailable"):
                store.resolve_many("target-a", [item.id])
            self.assertFalse(item.path.exists())


class BridgeHTTPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        target = Target("default", "ChatGPT", "restart-required", "restart-required", "default")
        self.multi = FakeMultiProfile([target])
        self.bridge = BridgeServer(self.multi, "capability", None)
        self.server = await asyncio.start_server(self.bridge.handle, "127.0.0.1", 0)
        socket_info = self.server.sockets[0].getsockname()
        self.port = int(socket_info[1])

    async def asyncTearDown(self) -> None:
        self.server.close()
        await self.server.wait_closed()
        self.bridge.close()

    async def request(
        self,
        path: str,
        authorization: str | None = None,
        *,
        method: str = "GET",
        body: dict[str, object] | bytes | None = None,
        content_type: str = "application/json",
        headers: dict[str, str] | None = None,
    ) -> tuple[int, bytes]:
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
        raw_body = b""
        if isinstance(body, dict):
            raw_body = json.dumps(body, separators=(",", ":")).encode("utf-8")
        elif isinstance(body, bytes):
            raw_body = body
        lines = [f"{method} {path} HTTP/1.1", f"Host: 127.0.0.1:{self.port}"]
        if authorization:
            lines.append(f"Authorization: {authorization}")
        if body is not None:
            lines.append(f"Content-Type: {content_type}")
            lines.append(f"Content-Length: {len(raw_body)}")
        for name, value in (headers or {}).items():
            lines.append(f"{name}: {value}")
        writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("ascii") + raw_body)
        await writer.drain()
        data = await reader.read()
        writer.close()
        await writer.wait_closed()
        header, body = data.split(b"\r\n\r\n", 1)
        status = int(header.split(b" ", 2)[1])
        return status, body

    async def test_targets_require_capability_and_return_dynamic_contract(self):
        status, _ = await self.request("/targets")
        self.assertEqual(status, 401)
        status, body = await self.request("/targets", "Bearer capability")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertEqual(payload["contractVersion"], 1)
        self.assertEqual(payload["targets"][0]["activationState"], "restart-required")

    async def test_ping_requires_capability_and_does_not_refresh_runtime_or_endpoints(self):
        runtime_refresh_calls = 0
        endpoint_calls = 0
        original_targets = self.multi.targets

        def targets(*, refresh=False):
            nonlocal runtime_refresh_calls
            if refresh:
                runtime_refresh_calls += 1
            return original_targets(refresh=refresh)

        def endpoint_provider():
            nonlocal endpoint_calls
            endpoint_calls += 1
            return [ConnectionEndpoint("lan", "Local network", "ws://192.168.77.2:8765", 10)]

        self.multi.targets = targets
        self.bridge.endpoint_provider = endpoint_provider

        status, _ = await self.request("/ping")
        self.assertEqual(status, 401)
        status, body = await self.request("/ping", "Bearer capability")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["contractVersion"], 1)
        self.assertEqual(runtime_refresh_calls, 0)
        self.assertEqual(endpoint_calls, 0)

    async def test_chat_prepare_requires_capability_and_forwards_explicit_relaunch(self):
        calls = []

        def prepare_chat(target, *, allow_relaunch=False):
            calls.append((target.id, allow_relaunch))
            return SharedSession(
                target.id,
                "ws://127.0.0.1:19444",
                4321,
                "http://127.0.0.1:19222",
            )

        self.multi.prepare_chat = prepare_chat
        route = self.multi.targets()[0].route_key
        path = f"/targets/{route}/chat-prepare"
        status, _ = await self.request(
            path,
            method="POST",
            body={"allowRelaunch": True},
        )
        self.assertEqual(status, 401)
        self.assertEqual(calls, [])

        status, body = await self.request(
            path,
            "Bearer capability",
            method="POST",
            body={"allowRelaunch": True},
        )
        self.assertEqual(status, 200)
        self.assertEqual(calls, [("default", True)])
        self.assertEqual(json.loads(body)["chatMirrorState"], "ready")

    async def test_pairing_endpoint_is_one_use(self):
        with tempfile.TemporaryDirectory() as temp:
            token_file = Path(temp) / "bootstrap"
            token_file.write_text("bootstrap", encoding="utf-8")
            self.bridge.pairing = PairingState("bootstrap", "capability", token_file)
            self.bridge.endpoints = [
                ConnectionEndpoint("lan", "Local network", "ws://192.168.77.2:8765", 10),
                ConnectionEndpoint("tailscale", "Tailscale", "ws://mac.example.ts.net:8765", 20),
            ]
            status, body = await self.request("/pair", "Bearer bootstrap")
            self.assertEqual(status, 200)
            payload = json.loads(body)
            self.assertEqual(payload["contractVersion"], 2)
            self.assertEqual(payload["capabilityToken"], "capability")
            self.assertEqual([item["kind"] for item in payload["endpoints"]], ["lan", "tailscale"])
            self.assertFalse(token_file.exists())
            status, _ = await self.request("/pair", "Bearer bootstrap")
            self.assertEqual(status, 404)

    async def test_connection_info_requires_capability(self):
        self.bridge.endpoints = [
            ConnectionEndpoint("zerotier", "ZeroTier", "ws://10.42.17.1:8765", 40)
        ]
        status, _ = await self.request("/connection-info")
        self.assertEqual(status, 401)
        status, body = await self.request("/connection-info", "Bearer capability")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertEqual(payload["contractVersion"], 1)
        self.assertEqual(payload["endpoints"][0]["kind"], "zerotier")

    async def test_connection_info_recomputes_dynamic_endpoints(self):
        values = [
            [ConnectionEndpoint("lan", "Local network", "ws://192.168.77.2:8765", 10)],
            [ConnectionEndpoint("tailscale", "Tailscale", "ws://mac.example.ts.net:8765", 20)],
        ]
        index = 0

        def provider():
            nonlocal index
            value = values[min(index, len(values) - 1)]
            index += 1
            return value

        self.bridge.endpoint_provider = provider
        status, body = await self.request("/connection-info", "Bearer capability")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["endpoints"][0]["kind"], "lan")
        status, body = await self.request("/connection-info", "Bearer capability")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["endpoints"][0]["kind"], "tailscale")

    async def test_chat_catalog_requires_capability_and_uses_opaque_target_route(self):
        payload = {
            "contractVersion": 1,
            "entries": [{"id": "conversation", "title": "Project chat"}],
            "projects": [],
        }
        self.bridge.chat_catalog_provider = lambda target: payload
        route = self.multi.targets()[0].route_key
        status, _ = await self.request(f"/targets/{route}/chat-catalog")
        self.assertEqual(status, 401)
        status, body = await self.request(
            f"/targets/{route}/chat-catalog",
            "Bearer capability",
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), payload)

    async def test_chat_transcript_requires_capability_and_stays_behind_opaque_target_route(self):
        payload = {
            "contractVersion": 1,
            "conversationId": "cloud-conversation",
            "title": "Project chat",
            "projectId": "project",
            "projectName": "Project",
            "source": "desktop-renderer",
            "messages": [{"role": "user", "text": "hello", "segments": ["hello"]}],
            "activity": "idle",
            "isPartial": False,
            "messageCount": 1,
        }
        self.bridge.chat_transcript_provider = lambda target, conversation_id: payload
        route = self.multi.targets()[0].route_key
        path = f"/targets/{route}/chat-conversations/cloud-conversation"
        status, _ = await self.request(path)
        self.assertEqual(status, 401)
        status, body = await self.request(path, "Bearer capability")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), payload)

    async def test_chat_transcript_reports_renderer_reason_without_leaking_details(self):
        def provider(target, conversation_id):
            raise ChatTranscriptUnavailable("desktop-renderer-unavailable")

        self.bridge.chat_transcript_provider = provider
        route = self.multi.targets()[0].route_key
        status, body = await self.request(
            f"/targets/{route}/chat-conversations/cloud-conversation",
            "Bearer capability",
        )
        self.assertEqual(status, 409)
        self.assertEqual(json.loads(body), {"error": "desktop-renderer-unavailable"})

    async def test_chat_transcript_sanitizes_unstructured_provider_error(self):
        def provider(target, conversation_id):
            raise RuntimeError("private/path should not cross the bridge")

        self.bridge.chat_transcript_provider = provider
        route = self.multi.targets()[0].route_key
        status, body = await self.request(
            f"/targets/{route}/chat-conversations/cloud-conversation",
            "Bearer capability",
        )
        self.assertEqual(status, 503)
        self.assertEqual(json.loads(body), {"error": "chat-transcript-unavailable"})

    async def test_chat_transcript_serializes_desktop_selection_per_target(self):
        state_lock = threading.Lock()
        active = 0
        max_active = 0

        def provider(target, conversation_id):
            nonlocal active, max_active
            with state_lock:
                active += 1
                max_active = max(max_active, active)
            time.sleep(0.05)
            with state_lock:
                active -= 1
            return {
                "contractVersion": 1,
                "conversationId": conversation_id,
                "messages": [],
                "activity": "idle",
                "isPartial": False,
                "messageCount": 0,
            }

        self.bridge.chat_transcript_provider = provider
        route = self.multi.targets()[0].route_key
        first, second = await asyncio.gather(
            self.request(
                f"/targets/{route}/chat-conversations/first",
                "Bearer capability",
            ),
            self.request(
                f"/targets/{route}/chat-conversations/second",
                "Bearer capability",
            ),
        )
        self.assertEqual(first[0], 200)
        self.assertEqual(second[0], 200)
        self.assertEqual(max_active, 1)

    async def test_chat_send_is_authenticated_idempotent_and_detects_request_id_conflict(self):
        calls = []

        def provider(target, conversation_id, text, request_id, attachments):
            calls.append((target.id, conversation_id, text, request_id, attachments))
            return {
                "contractVersion": 1,
                "conversationId": conversation_id,
                "clientRequestId": request_id,
                "status": "submitted",
                "source": "desktop-renderer",
            }

        self.bridge.chat_message_provider = provider
        route = self.multi.targets()[0].route_key
        path = f"/targets/{route}/chat-conversations/cloud-conversation/messages"
        request = {"contractVersion": 1, "clientRequestId": "request-1", "text": "hello"}
        status, _ = await self.request(path, method="POST", body=request)
        self.assertEqual(status, 401)

        first_status, first_body = await self.request(
            path,
            "Bearer capability",
            method="POST",
            body=request,
        )
        second_status, second_body = await self.request(
            path,
            "Bearer capability",
            method="POST",
            body=request,
        )
        self.assertEqual(first_status, 200)
        self.assertEqual(second_status, 200)
        self.assertEqual(json.loads(first_body), json.loads(second_body))
        self.assertEqual(calls, [("default", "cloud-conversation", "hello", "request-1", [])])

        conflict_status, conflict_body = await self.request(
            path,
            "Bearer capability",
            method="POST",
            body={"contractVersion": 1, "clientRequestId": "request-1", "text": "different"},
        )
        self.assertEqual(conflict_status, 409)
        self.assertEqual(json.loads(conflict_body), {"error": "client-request-id-conflict"})

    async def test_chat_attachment_upload_is_target_scoped_and_consumed_after_confirmed_send(self):
        calls = []

        def provider(target, conversation_id, text, request_id, attachments):
            calls.append((
                target.id,
                conversation_id,
                text,
                request_id,
                [(item.filename, item.mime_type, item.path.is_file()) for item in attachments],
            ))
            return {
                "contractVersion": 1,
                "conversationId": conversation_id,
                "clientRequestId": request_id,
                "status": "submitted",
                "source": "desktop-renderer",
            }

        self.bridge.chat_message_provider = provider
        route = self.multi.targets()[0].route_key
        upload_path = f"/targets/{route}/chat-attachments"
        status, _ = await self.request(
            upload_path,
            method="POST",
            body=b"fake-png",
            content_type="image/png",
            headers={"X-Plura-Filename": "Photo%20one.png"},
        )
        self.assertEqual(status, 401)

        status, body = await self.request(
            upload_path,
            "Bearer capability",
            method="POST",
            body=b"fake-png",
            content_type="image/png",
            headers={"X-Plura-Filename": "Photo%20one.png"},
        )
        self.assertEqual(status, 200)
        attachment = json.loads(body)
        self.assertEqual(attachment["filename"], "Photo one.png")
        self.assertEqual(attachment["mimeType"], "image/png")
        self.assertEqual(attachment["size"], 8)

        send_path = f"/targets/{route}/chat-conversations/cloud-conversation/messages"
        request = {
            "contractVersion": 1,
            "clientRequestId": "request-with-file",
            "text": "",
            "attachmentIds": [attachment["attachmentId"]],
        }
        first_status, first_body = await self.request(
            send_path,
            "Bearer capability",
            method="POST",
            body=request,
        )
        second_status, second_body = await self.request(
            send_path,
            "Bearer capability",
            method="POST",
            body=request,
        )
        self.assertEqual(first_status, 200)
        self.assertEqual(second_status, 200)
        self.assertEqual(json.loads(first_body), json.loads(second_body))
        self.assertEqual(calls, [(
            "default",
            "cloud-conversation",
            "",
            "request-with-file",
            [("Photo one.png", "image/png", True)],
        )])
        with self.assertRaisesRegex(ValueError, "chat-attachment-unavailable"):
            self.bridge.chat_attachment_store.resolve_many(
                "default",
                [attachment["attachmentId"]],
            )

    async def test_chat_send_rejects_malformed_body_and_marks_uncertain_result_not_retry_safe(self):
        route = self.multi.targets()[0].route_key
        path = f"/targets/{route}/chat-conversations/cloud-conversation/messages"
        self.bridge.chat_message_provider = lambda *args: (_ for _ in ()).throw(
            RuntimeError("chat-send-uncertain")
        )

        status, body = await self.request(
            path,
            "Bearer capability",
            method="POST",
            body=b"not-json",
        )
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(body), {"error": "chat-message-invalid"})

        status, body = await self.request(
            path,
            "Bearer capability",
            method="POST",
            body={"contractVersion": 1, "clientRequestId": "request-2", "text": "hello"},
        )
        self.assertEqual(status, 503)
        self.assertEqual(json.loads(body), {"error": "chat-send-uncertain", "retrySafe": False})

    async def test_chat_send_reports_renderer_preflight_failure_as_conflict(self):
        route = self.multi.targets()[0].route_key
        path = f"/targets/{route}/chat-conversations/cloud-conversation/messages"
        self.bridge.chat_message_provider = lambda *args: (_ for _ in ()).throw(
            RuntimeError("desktop-renderer-unavailable")
        )
        status, body = await self.request(
            path,
            "Bearer capability",
            method="POST",
            body={"contractVersion": 1, "clientRequestId": "request-3", "text": "hello"},
        )
        self.assertEqual(status, 409)
        self.assertEqual(json.loads(body), {"error": "desktop-renderer-unavailable"})


class ChatCatalogTests(unittest.TestCase):
    def test_read_catalog_returns_only_safe_sidebar_metadata(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            sqlite_dir = home / "sqlite"
            sqlite_dir.mkdir()
            database = sqlite_dir / "codex-dev.db"
            connection = sqlite3.connect(database)
            connection.executescript(
                """
                CREATE TABLE local_thread_catalog_hosts (host_id TEXT PRIMARY KEY, host_kind TEXT NOT NULL);
                CREATE TABLE local_thread_catalog_sync_state (
                    host_id TEXT PRIMARY KEY,
                    watermark_updated_at REAL,
                    initial_build_complete INTEGER NOT NULL DEFAULT 0,
                    observation_sequence INTEGER NOT NULL DEFAULT 0,
                    last_full_reconciled_at INTEGER
                );
                CREATE TABLE local_thread_catalog (
                    host_id TEXT NOT NULL,
                    thread_id TEXT NOT NULL,
                    display_title TEXT NOT NULL,
                    source_created_at REAL NOT NULL,
                    source_updated_at REAL NOT NULL,
                    source_recency_at REAL NOT NULL,
                    source_kind TEXT NOT NULL,
                    project_id TEXT,
                    missing_candidate INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (host_id, thread_id)
                );
                """
            )
            chat_host = "chatgpt:account-safe:user-safe"
            connection.execute("INSERT INTO local_thread_catalog_hosts VALUES (?, 'chatgpt')", (chat_host,))
            connection.execute("INSERT INTO local_thread_catalog_hosts VALUES ('local', 'local')")
            connection.execute(
                "INSERT INTO local_thread_catalog_sync_state VALUES (?, 20, 1, 1, 30)",
                (chat_host,),
            )
            connection.execute(
                "INSERT INTO local_thread_catalog VALUES (?, 'cloud', 'Project chat', 10, 20, 20, 'chatgpt', 'g-p-safe', 0)",
                (chat_host,),
            )
            connection.execute(
                "INSERT INTO local_thread_catalog VALUES ('local', 'local-thread', 'Local chat', 9, 19, 19, 'vscode', NULL, 0)"
            )
            connection.execute(
                "INSERT INTO local_thread_catalog VALUES (?, 'stale-cloud', 'Stale project chat', 8, 18, 18, 'chatgpt', 'g-p-stale', 0)",
                (chat_host,),
            )
            connection.commit()
            connection.close()
            (home / ".codex-global-state.json").write_text(
                json.dumps(
                    {
                        "electron-persisted-atom-state": {
                            "chatgpt-sidebar-state-v1": {
                                "account-safe": {
                                    "projects": [{"id": "g-p-safe", "name": "Safe Project"}],
                                    "pinnedProjects": [
                                        {"project": {"id": "g-p-safe", "name": "Safe Project"}}
                                    ],
                                    "pinnedConversations": [],
                                },
                            },
                            "unified-sidebar-pinned-order-v1": ["chatgpt:project:g-p-safe"],
                            "sensitive-other-state": {"token": "must-not-leak"},
                        }
                    }
                ),
                encoding="utf-8",
            )

            payload = _read_catalog(home)
            self.assertEqual(payload["contractVersion"], 1)
            self.assertEqual([item["title"] for item in payload["entries"]], ["Project chat", "Local chat"])
            self.assertEqual(payload["entries"][0]["projectName"], "Safe Project")
            self.assertFalse(payload["entries"][0]["canOpenRemotely"])
            self.assertTrue(payload["entries"][1]["canOpenRemotely"])
            self.assertEqual(
                payload["projects"],
                [{"id": "g-p-safe", "name": "Safe Project", "isPinned": True, "sortOrder": 0}],
            )
            self.assertNotIn("must-not-leak", json.dumps(payload))


if __name__ == "__main__":
    unittest.main()
