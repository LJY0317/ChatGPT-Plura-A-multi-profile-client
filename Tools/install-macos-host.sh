#!/bin/sh
set -eu

LABEL='io.github.LJY0317.PluraMobile.host'
APP_SUPPORT="$HOME/Library/Application Support/ChatGPT Plura — A multi-profile client"
RUNTIME="$APP_SUPPORT/host-runtime"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=$(command -v python3 || true)
PLURA_DESKTOP_CLI="$HOME/Library/Application Support/PluraDesktop/plura-desktop"
LEGACY_DESKTOP_CLI="$HOME/Library/Application Support/CodexMultiProfileLauncher/codex-profile"
OFFICIAL_CHATGPT='/Applications/ChatGPT.app'

if [ -z "$PYTHON" ]; then
    echo 'python3 is required to install Plura Host.' >&2
    exit 1
fi
if [ ! -x "$PLURA_DESKTOP_CLI" ] && [ ! -x "$LEGACY_DESKTOP_CLI" ]; then
    echo 'Plura Desktop is not installed or its control CLI is unavailable.' >&2
    echo "Expected: $PLURA_DESKTOP_CLI" >&2
    exit 1
fi
if [ ! -d "$OFFICIAL_CHATGPT" ]; then
    echo 'The official ChatGPT macOS application is required.' >&2
    echo "Expected: $OFFICIAL_CHATGPT" >&2
    exit 1
fi
if [ -L "$APP_SUPPORT" ] || [ -L "$RUNTIME" ] || [ -L "$PLIST" ]; then
    echo 'Refusing to install through a symlinked Plura host path.' >&2
    exit 1
fi

mkdir -p "$APP_SUPPORT" "$HOME/Library/LaunchAgents"
rm -rf "$RUNTIME"
mkdir -p "$RUNTIME"
cp "$SCRIPT_DIR/chatgpt-plura-host.py" "$RUNTIME/chatgpt-plura-host.py"
cp -R "$SCRIPT_DIR/chatgpt_plura_host" "$RUNTIME/chatgpt_plura_host"
chmod 755 "$RUNTIME/chatgpt-plura-host.py"
find "$RUNTIME" -type d -name '__pycache__' -prune -exec rm -rf '{}' '+'

UID_VALUE=$(id -u)
launchctl bootout "gui/$UID_VALUE" "$PLIST" >/dev/null 2>&1 || true

"$PYTHON" - "$PLIST" "$PYTHON" "$RUNTIME/chatgpt-plura-host.py" "$RUNTIME" <<'PY'
from pathlib import Path
import plistlib
import sys

plist, python, script, working = sys.argv[1:]
payload = {
    "Label": "io.github.LJY0317.PluraMobile.host",
    "ProgramArguments": [
        python,
        script,
        "--listen-host",
        "0.0.0.0",
        "--listen-port",
        "8765",
    ],
    "WorkingDirectory": working,
    "RunAtLoad": True,
    "KeepAlive": True,
    "ProcessType": "Background",
    "ThrottleInterval": 10,
    "StandardOutPath": "/dev/null",
    "StandardErrorPath": "/dev/null",
}
Path(plist).write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=True))
PY

chmod 600 "$PLIST"
launchctl bootstrap "gui/$UID_VALUE" "$PLIST"
launchctl enable "gui/$UID_VALUE/$LABEL"
launchctl kickstart -k "gui/$UID_VALUE/$LABEL"

echo "Installed Plura Host LaunchAgent: $LABEL"
echo "Runtime: $RUNTIME"
echo 'Prerequisites verified: official ChatGPT app + Plura Desktop control runtime.'
