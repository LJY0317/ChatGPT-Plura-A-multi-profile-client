from __future__ import annotations

from dataclasses import dataclass
import ipaddress
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from urllib.parse import urlsplit

from .platform import lan_ipv4


@dataclass(frozen=True)
class ConnectionEndpoint:
    kind: str
    label: str
    url: str
    priority: int

    def public(self) -> dict[str, object]:
        return {
            "kind": self.kind,
            "label": self.label,
            "url": self.url,
            "priority": self.priority,
        }


def _endpoint_url(host: str, port: int) -> str:
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return f"ws://{host}:{port}"


def _validate_endpoint_url(value: str) -> str:
    parsed = urlsplit(value.strip())
    if parsed.scheme not in {"ws", "wss"} or not parsed.hostname:
        raise ValueError("Advertised endpoint must use ws:// or wss:// with a hostname")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Advertised endpoint must not contain credentials, query, or fragment")
    if parsed.path not in {"", "/"}:
        raise ValueError("Advertised endpoint must not contain a path")
    if parsed.port is None or not 1 <= parsed.port <= 65535:
        raise ValueError("Advertised endpoint must include a valid port")
    return value.strip().rstrip("/")


def _usable_overlay_ip(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return not (
        address.is_loopback
        or address.is_link_local
        or address.is_multicast
        or address.is_unspecified
    )


def _tailscale_endpoints_from_status(output: str, port: int) -> list[ConnectionEndpoint]:
    try:
        payload = json.loads(output)
    except json.JSONDecodeError:
        return []
    current = payload.get("Self") if isinstance(payload, dict) else None
    if not isinstance(current, dict):
        return []
    endpoints: list[ConnectionEndpoint] = []
    dns_name = current.get("DNSName")
    if isinstance(dns_name, str) and dns_name.strip(". "):
        name = dns_name.strip().rstrip(".")
        endpoints.append(ConnectionEndpoint("tailscale", "Tailscale", _endpoint_url(name, port), 20))
    for value in current.get("TailscaleIPs", []):
        if isinstance(value, str) and _usable_overlay_ip(value):
            endpoints.append(ConnectionEndpoint("tailscale", "Tailscale IP", _endpoint_url(value, port), 30))
    return endpoints


def _tailscale_cli() -> str | None:
    if executable := shutil.which("tailscale"):
        return executable
    if sys.platform == "darwin":
        bundled = Path("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        if bundled.is_file():
            return str(bundled)
    return None


def _zerotier_endpoints_from_networks(output: str, port: int) -> list[ConnectionEndpoint]:
    try:
        payload = json.loads(output)
    except json.JSONDecodeError:
        return []
    if not isinstance(payload, list):
        return []
    endpoints: list[ConnectionEndpoint] = []
    for network in payload:
        if not isinstance(network, dict) or str(network.get("status", "")).upper() != "OK":
            continue
        for assigned in network.get("assignedAddresses", []):
            if not isinstance(assigned, str):
                continue
            value = assigned.split("/", 1)[0]
            if _usable_overlay_ip(value):
                endpoints.append(ConnectionEndpoint("zerotier", "ZeroTier", _endpoint_url(value, port), 40))
    return endpoints


def _netbird_endpoint(port: int) -> ConnectionEndpoint | None:
    try:
        if sys.platform == "darwin":
            output = subprocess.check_output(["/sbin/ifconfig", "wt0"], text=True, stderr=subprocess.DEVNULL)
            for line in output.splitlines():
                fields = line.split()
                if len(fields) >= 2 and fields[0] == "inet" and _usable_overlay_ip(fields[1]):
                    return ConnectionEndpoint("netbird", "NetBird", _endpoint_url(fields[1], port), 50)
        elif sys.platform.startswith("linux") and (ip := shutil.which("ip")):
            output = subprocess.check_output(
                [ip, "-o", "-4", "addr", "show", "dev", "wt0"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
            for line in output.splitlines():
                fields = line.split()
                if len(fields) >= 4:
                    value = fields[3].split("/", 1)[0]
                    if _usable_overlay_ip(value):
                        return ConnectionEndpoint("netbird", "NetBird", _endpoint_url(value, port), 50)
        elif sys.platform == "win32":
            powershell = shutil.which("powershell.exe") or shutil.which("pwsh.exe") or shutil.which("pwsh")
            if powershell:
                script = (
                    "Get-NetIPAddress -InterfaceAlias 'wt0' -AddressFamily IPv4 -ErrorAction SilentlyContinue | "
                    "ForEach-Object { $_.IPAddress }"
                )
                output = subprocess.check_output(
                    [powershell, "-NoProfile", "-NonInteractive", "-Command", script],
                    text=True,
                    stderr=subprocess.DEVNULL,
                )
                for value in output.splitlines():
                    value = value.strip()
                    if _usable_overlay_ip(value):
                        return ConnectionEndpoint("netbird", "NetBird", _endpoint_url(value, port), 50)
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def discover_connection_endpoints(port: int, explicit: list[str] | None = None) -> list[ConnectionEndpoint]:
    endpoints: list[ConnectionEndpoint] = []
    lan = lan_ipv4()
    if lan != "127.0.0.1":
        endpoints.append(ConnectionEndpoint("lan", "Local network", _endpoint_url(lan, port), 10))

    tailscale = _tailscale_cli()
    if tailscale:
        try:
            environment = os.environ.copy()
            if sys.platform == "darwin" and tailscale.endswith("/Tailscale.app/Contents/MacOS/Tailscale"):
                environment["TAILSCALE_BE_CLI"] = "1"
            output = subprocess.check_output(
                [tailscale, "status", "--json"],
                text=True,
                stderr=subprocess.DEVNULL,
                env=environment,
            )
            endpoints.extend(_tailscale_endpoints_from_status(output, port))
        except (OSError, subprocess.SubprocessError):
            pass

    zerotier = shutil.which("zerotier-cli")
    if zerotier:
        try:
            output = subprocess.check_output([zerotier, "-j", "listnetworks"], text=True, stderr=subprocess.DEVNULL)
            endpoints.extend(_zerotier_endpoints_from_networks(output, port))
        except (OSError, subprocess.SubprocessError):
            pass

    if endpoint := _netbird_endpoint(port):
        endpoints.append(endpoint)

    for index, value in enumerate(explicit or []):
        endpoints.append(
            ConnectionEndpoint("custom", "Private overlay", _validate_endpoint_url(value), 60 + index)
        )

    unique: dict[str, ConnectionEndpoint] = {}
    for endpoint in sorted(endpoints, key=lambda item: item.priority):
        unique.setdefault(endpoint.url, endpoint)
    return list(unique.values())
