#!/bin/sh
set -eu

LABEL='io.github.LJY0317.PluraMobile.host'
APP_SUPPORT="$HOME/Library/Application Support/ChatGPT Plura — A multi-profile client"
RUNTIME="$APP_SUPPORT/host-runtime"
STATE="$APP_SUPPORT/host"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
KEYCHAIN_SERVICE='io.github.LJY0317.PluraMobile.bridge'
KEYCHAIN_ACCOUNT=${CHATGPT_PLURA_KEYCHAIN_ACCOUNT:-${USER:-}}
UID_VALUE=$(id -u)
PURGE=0

case "${1:-}" in
    '') ;;
    --purge) PURGE=1 ;;
    *)
        echo 'Usage: Tools/uninstall-macos-host.sh [--purge]' >&2
        exit 2
        ;;
esac

launchctl bootout "gui/$UID_VALUE" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"
rm -rf "$RUNTIME"

if [ "$PURGE" -eq 1 ]; then
    if [ -L "$APP_SUPPORT" ] || [ -L "$STATE" ]; then
        echo 'Refusing to purge through a symlinked Plura state path.' >&2
        exit 1
    fi
    rm -rf "$STATE"
    if [ -n "$KEYCHAIN_ACCOUNT" ]; then
        security delete-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
    else
        security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
    fi
    rmdir "$APP_SUPPORT" >/dev/null 2>&1 || true
    echo 'Removed the Plura Host runtime, LaunchAgent, host state, and bridge pairing credential.'
else
    echo 'Removed the Plura Host LaunchAgent and installed host runtime.'
    echo 'Pairing credentials and host state were preserved. Re-run with --purge for full Plura-host removal.'
fi
