#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
from pathlib import Path
import sys

from chatgpt_plura_host.bridge import BridgeServer, PairingState
from chatgpt_plura_host.catalog import TargetChatCatalogProvider
from chatgpt_plura_host.plura_desktop import PluraDesktopClient
from chatgpt_plura_host.network import discover_connection_endpoints
from chatgpt_plura_host.platform import current_platform
from chatgpt_plura_host.renderer import TargetChatComposerProvider, TargetChatTranscriptProvider


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Authenticated Plura host bridge")
    parser.add_argument("--listen-host", default="0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=8765)
    parser.add_argument("--show-pairing", action="store_true")
    parser.add_argument("--reset-pairing", action="store_true")
    parser.add_argument("--pairing-bootstrap-file", type=Path)
    parser.add_argument(
        "--advertise-endpoint",
        action="append",
        default=[],
        help="Additional reachable ws:// or wss:// endpoint (repeatable; useful for WireGuard/overlay hostnames)",
    )
    return parser.parse_args()


async def run(args: argparse.Namespace) -> None:
    platform = current_platform()
    platform.state_dir.mkdir(parents=True, exist_ok=True)
    token, created = platform.credential_store.load_or_create(reset=args.reset_pairing)

    # Pairing-token display is an operator query, not a request to start a
    # second bridge server. Keeping it one-shot means it remains usable while
    # the installed LaunchAgent already owns the normal listen port.
    if args.show_pairing:
        endpoints = discover_connection_endpoints(args.listen_port, args.advertise_endpoint)
        print("Plura Host pairing")
        if endpoints:
            print("Reachable endpoints:")
            for endpoint in endpoints:
                print(f"  {endpoint.label}: {endpoint.url}")
        else:
            print("Reachable endpoints: none detected; use --advertise-endpoint for a private overlay hostname/IP")
        print(f"Pairing token (enter once): {token}")
        if args.reset_pairing:
            print("Pairing token: rotated")
        elif created:
            print("Pairing token: created")
        else:
            print("Pairing token: current")
        return

    if not platform.control_cli.is_file():
        raise RuntimeError(f"Plura Desktop control CLI is missing: {platform.control_cli}")

    pairing = None
    if args.pairing_bootstrap_file is not None:
        bootstrap = args.pairing_bootstrap_file.read_text(encoding="utf-8").strip()
        if not bootstrap:
            raise RuntimeError("pairing bootstrap file is empty")
        pairing = PairingState(bootstrap, token, args.pairing_bootstrap_file)

    desktop_runtime = PluraDesktopClient(platform.control_cli)
    desktop_runtime.targets(refresh=True)
    def endpoint_provider():
        return discover_connection_endpoints(args.listen_port, args.advertise_endpoint)

    endpoints = endpoint_provider()
    chat_catalog_provider = TargetChatCatalogProvider(desktop_runtime)
    bridge = BridgeServer(
        desktop_runtime,
        token,
        pairing,
        endpoints,
        endpoint_provider,
        chat_catalog_provider=chat_catalog_provider,
        chat_transcript_provider=TargetChatTranscriptProvider(desktop_runtime, chat_catalog_provider),
        chat_message_provider=TargetChatComposerProvider(desktop_runtime, chat_catalog_provider),
    )
    server = await asyncio.start_server(bridge.handle, args.listen_host, args.listen_port)

    print("Plura Host")
    if endpoints:
        print("Reachable endpoints:")
        for endpoint in endpoints:
            print(f"  {endpoint.label}: {endpoint.url}")
    else:
        print("Reachable endpoints: none detected; use --advertise-endpoint for a private overlay hostname/IP")
    print("Targets: authenticated GET /targets")
    if created:
        print(f"Pairing token (enter once): {token}")
    else:
        print("Pairing token: reused from the platform credential store")
    if pairing is not None:
        print("One-time pairing endpoint: enabled")
    print("Plura Desktop owns canonical target runtimes; this host only attaches and never creates a fallback writer.")
    try:
        async with server:
            await server.serve_forever()
    finally:
        bridge.close()


def main() -> int:
    args = parse_args()
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        return 0
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
