#!/usr/bin/env python3
"""Plura Mobile's independent local Personal Team refresh entry point."""
from pathlib import Path
from signing_refresh import entrypoint

SPEC = {
    "name": "Plura Mobile",
    "support": "ChatGPT Plura — A multi-profile client/SigningRefresh",
    "app": "Plura Mobile.app",
    "project": "ChatGPT Plura — A multi-profile client.xcodeproj",
    "scheme": "ChatGPT Plura — A multi-profile client",
    "sources": ["Sources", "Support", "ChatGPT Plura — A multi-profile client.xcodeproj", "project.yml"],
    "label": "local.plura-mobile.refresh", "entry": "Tools/refresh.py", "minute": 20,
}

if __name__ == "__main__":
    raise SystemExit(entrypoint(Path(__file__).resolve().parent.parent, SPEC))
