from __future__ import annotations

from dataclasses import dataclass
import ipaddress
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys


SERVICE = "io.github.LJY0317.PluraMobile.bridge"


class CredentialStore:
    def load(self) -> str | None:
        raise NotImplementedError

    def save(self, value: str) -> None:
        raise NotImplementedError

    def delete(self) -> None:
        raise NotImplementedError

    def load_or_create(self, *, reset: bool = False) -> tuple[str, bool]:
        if reset:
            self.delete()
        value = self.load()
        if value:
            return value, False
        value = secrets.token_hex(24)
        self.save(value)
        return value, True


class MacOSCredentialStore(CredentialStore):
    def __init__(self) -> None:
        self.account = os.environ.get("CHATGPT_PLURA_KEYCHAIN_ACCOUNT", os.environ.get("USER", "chatgpt-plura"))
        self.service = os.environ.get("CHATGPT_PLURA_KEYCHAIN_SERVICE", SERVICE)

    def load(self) -> str | None:
        result = subprocess.run(
            ["security", "find-generic-password", "-a", self.account, "-s", self.service, "-w"],
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            return None
        value = result.stdout.strip()
        return value or None

    def save(self, value: str) -> None:
        subprocess.run(
            ["security", "add-generic-password", "-U", "-a", self.account, "-s", self.service, "-w", value],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def delete(self) -> None:
        subprocess.run(
            ["security", "delete-generic-password", "-a", self.account, "-s", self.service],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


class LinuxCredentialStore(CredentialStore):
    def __init__(self) -> None:
        self.secret_tool = shutil.which("secret-tool")
        if not self.secret_tool:
            raise RuntimeError("Linux Secret Service client 'secret-tool' is required for Plura pairing")

    def load(self) -> str | None:
        result = subprocess.run(
            [self.secret_tool, "lookup", "service", SERVICE],
            text=True,
            capture_output=True,
        )
        value = result.stdout.strip() if result.returncode == 0 else ""
        return value or None

    def save(self, value: str) -> None:
        subprocess.run(
            [self.secret_tool, "store", "--label", "Plura bridge credential", "service", SERVICE],
            input=value,
            text=True,
            check=True,
            stdout=subprocess.DEVNULL,
        )

    def delete(self) -> None:
        subprocess.run(
            [self.secret_tool, "clear", "service", SERVICE],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


class WindowsCredentialStore(CredentialStore):
    def __init__(self, state_dir: Path) -> None:
        self.state_dir = state_dir
        self.path = state_dir / "bridge-credential.dpapi"
        self.powershell = shutil.which("powershell.exe") or shutil.which("pwsh.exe") or shutil.which("pwsh")
        if not self.powershell:
            raise RuntimeError("PowerShell is required for Windows DPAPI credential storage")

    def load(self) -> str | None:
        if not self.path.is_file():
            return None
        script = (
            "$b=[IO.File]::ReadAllBytes($args[0]);"
            "$p=[Security.Cryptography.ProtectedData]::Unprotect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser);"
            "[Console]::Out.Write([Text.Encoding]::UTF8.GetString($p))"
        )
        result = subprocess.run(
            [self.powershell, "-NoProfile", "-NonInteractive", "-Command", script, str(self.path)],
            text=True,
            capture_output=True,
        )
        value = result.stdout.strip() if result.returncode == 0 else ""
        return value or None

    def save(self, value: str) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        script = (
            "$p=[Text.Encoding]::UTF8.GetBytes($args[1]);"
            "$b=[Security.Cryptography.ProtectedData]::Protect($p,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser);"
            "[IO.File]::WriteAllBytes($args[0],$b)"
        )
        subprocess.run(
            [self.powershell, "-NoProfile", "-NonInteractive", "-Command", script, str(self.path), value],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def delete(self) -> None:
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass


@dataclass(frozen=True)
class HostPlatform:
    id: str
    control_cli: Path
    state_dir: Path
    credential_store: CredentialStore


def current_platform() -> HostPlatform:
    home = Path.home()
    if sys.platform == "darwin":
        state = home / "Library/Application Support/ChatGPT Plura — A multi-profile client/host"
        cli = home / "Library/Application Support/PluraDesktop/plura-desktop"
        return HostPlatform("macos", cli, state, MacOSCredentialStore())
    if sys.platform == "win32":
        local = Path(os.environ.get("LOCALAPPDATA", home / "AppData/Local"))
        state = local / "ChatGPT Plura — A multi-profile client/host"
        cli = local / "PluraDesktop/plura-desktop.cmd"
        return HostPlatform("windows", cli, state, WindowsCredentialStore(state))
    if sys.platform.startswith("linux"):
        state_home = Path(os.environ.get("XDG_STATE_HOME", home / ".local/state"))
        state = state_home / "ChatGPT Plura — A multi-profile client/host"
        cli = state_home / "PluraDesktop/plura-desktop"
        return HostPlatform("linux", cli, state, LinuxCredentialStore())
    raise RuntimeError(f"Unsupported host platform: {sys.platform}")


_VIRTUAL_INTERFACE_PREFIXES = (
    "lo",
    "utun",
    "awdl",
    "llw",
    "bridge",
    "gif",
    "stf",
    "anpi",
    "ap",
    "nan",
    "docker",
    "veth",
    "virbr",
    "tun",
    "tap",
    "wg",
    "tailscale",
)


def _usable_ipv4(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return (
        address.version == 4
        and not address.is_loopback
        and not address.is_link_local
        and not address.is_multicast
        and not address.is_unspecified
    )


def _is_virtual_interface(name: str) -> bool:
    lowered = name.lower()
    return lowered.startswith(_VIRTUAL_INTERFACE_PREFIXES)


def _macos_lan_ipv4_from_ifconfig(output: str) -> str | None:
    blocks = re.split(r"(?m)(?=^[A-Za-z0-9])", output)
    for block in blocks:
        lines = block.splitlines()
        if not lines or ":" not in lines[0]:
            continue
        interface = lines[0].split(":", 1)[0]
        if _is_virtual_interface(interface) or "status: active" not in block:
            continue
        match = re.search(r"(?m)^\s*inet (\d+\.\d+\.\d+\.\d+)\b", block)
        if match and _usable_ipv4(match.group(1)):
            return match.group(1)
    return None


def _linux_lan_ipv4_from_ip(output: str) -> str | None:
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        interface = parts[1].split("@", 1)[0]
        if _is_virtual_interface(interface):
            continue
        try:
            address = parts[3].split("/", 1)[0]
        except IndexError:
            continue
        if _usable_ipv4(address):
            return address
    return None


def lan_ipv4() -> str:
    if sys.platform == "darwin":
        try:
            output = subprocess.check_output(["/sbin/ifconfig"], text=True)
            if address := _macos_lan_ipv4_from_ifconfig(output):
                return address
        except (OSError, subprocess.SubprocessError):
            pass
    elif sys.platform.startswith("linux"):
        ip = shutil.which("ip")
        if ip:
            try:
                output = subprocess.check_output(
                    [ip, "-o", "-4", "addr", "show", "up", "scope", "global"],
                    text=True,
                )
                if address := _linux_lan_ipv4_from_ip(output):
                    return address
            except (OSError, subprocess.SubprocessError):
                pass
    elif sys.platform == "win32":
        powershell = shutil.which("powershell.exe") or shutil.which("pwsh.exe") or shutil.which("pwsh")
        if powershell:
            script = (
                "Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface } | "
                "ForEach-Object { Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 "
                "-ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress } }"
            )
            try:
                output = subprocess.check_output(
                    [powershell, "-NoProfile", "-NonInteractive", "-Command", script],
                    text=True,
                )
                for value in output.splitlines():
                    value = value.strip()
                    if _usable_ipv4(value):
                        return value
            except (OSError, subprocess.SubprocessError):
                pass

    return "127.0.0.1"
