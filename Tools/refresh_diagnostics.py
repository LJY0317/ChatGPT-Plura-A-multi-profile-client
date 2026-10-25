"""Bounded, best-effort diagnostics for the local signing refresh job."""

import datetime as dt
import json
import os
import pathlib
import platform
import plistlib
import re
import subprocess
import sys
import tempfile


MAX_BYTES = 1024 * 1024
RETENTION = dt.timedelta(days=30)


class Diagnostics:
    def __init__(self, support):
        self.path = support / "diagnostics.json"
        self.context = {}
        self.replacements = []
        self.last_error = ""

    def configure(self, config):
        # Values are used only to redact command output, never persisted here.
        self.replacements = [str(value) for value in config.get("devices", [])]
        self.replacements += [str(config[key]) for key in ("team", "bundle_id") if config.get(key)]

    def clean(self, value):
        text = str(value).replace(str(pathlib.Path.home()), "~")
        for value in self.replacements:
            text = text.replace(value, "[configured value]")
        text = re.sub(r"[\w.+%-]+@[\w.-]+\.[A-Za-z]{2,}", "[email]", text)
        text = re.sub(r"(?i)((?:authorization|password|token|secret)\s*[:=]\s*)[^\s,;]+", r"\1[redacted]", text)
        text = re.sub(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}\b", "[identifier]", text)
        text = re.sub(r"\b\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+", "[time]", text)
        text = re.sub(r"\[\d+:\d+\]", "[process]", text)
        return text[:4096]

    def observe(self):
        try:
            self._observe()
        except Exception as error:
            self.context = {"observation_error": type(error).__name__}
            self.record("environment")

    def _observe(self):
        """Read non-secret metadata; Xcode preference format is only a clue."""
        context = {"macos": platform.mac_ver()[0]}
        try:
            selected = subprocess.run(["xcode-select", "-p"], capture_output=True,
                                      text=True, timeout=10)
            context["developer_directory"] = self.clean(selected.stdout.strip())
            context["xcode_select_exit"] = selected.returncode
            context["developer_directory_override"] = self.clean(os.environ.get("DEVELOPER_DIR", ""))
            developer = os.environ.get("DEVELOPER_DIR") or selected.stdout.strip()
            app = pathlib.Path(developer)
            if app.suffix != ".app":
                app = app.parent.parent
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            version = plistlib.loads((app / "Contents/version.plist").read_bytes())
            context["xcode_version"] = info.get("CFBundleShortVersionString")
            context["xcode_build"] = version.get("ProductBuildVersion")
        except (OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
            context["xcode_observation_error"] = type(error).__name__
        try:
            pref = pathlib.Path.home() / "Library/Preferences/com.apple.dt.Xcode.plist"
            data = plistlib.loads(pref.read_bytes())
            accounts = data.get("DVTDeveloperAccountManagerAppleIDLists", {}).get("IDE.Identifiers.Prod")
            context["account_count_hint"] = len(accounts) if isinstance(accounts, list) else None
            context["account_hint_source"] = "Xcode preferences (not authentication validation)"
        except (OSError, ValueError, AttributeError, plistlib.InvalidFileException) as error:
            context["account_count_hint"] = None
            context["account_observation_error"] = type(error).__name__
        self.context = context
        self.record("environment")

    def record(self, stage, **details):
        # A diagnostic failure must never change the signing/install result.
        try:
            now = dt.datetime.now(dt.timezone.utc)
            stamp = now.isoformat()
            try:
                data = json.loads(self.path.read_text())
            except (OSError, ValueError):
                data = {"events": []}
            events = [event for event in data["events"]
                      if dt.datetime.fromisoformat(event["last_seen"]) >= now - RETENTION]
            payload = {"stage": stage, "environment": self.context, **details}
            # Coalesce recurring outcomes, while preserving environment changes.
            previous = next((event for event in reversed(events)
                             if event["details"]["stage"] == stage), None)
            if previous and previous["details"] == payload:
                previous["last_seen"] = stamp
                previous["count"] += 1
                events.remove(previous)
                events.append(previous)
            else:
                events.append({"first_seen": stamp, "last_seen": stamp,
                               "count": 1, "details": payload})
            data = {"schema": 1, "last_check": stamp, "events": events}
            encoded = json.dumps(data, indent=2) + "\n"
            while len(encoded.encode()) > MAX_BYTES and len(events) > 1:
                events.pop(0)
                encoded = json.dumps(data, indent=2) + "\n"
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(encoded)
            os.chmod(temporary, 0o600)
            temporary.replace(self.path)
        except Exception as error:
            print(f"Diagnostic write unavailable: {type(error).__name__}", file=sys.stderr)

    def command(self, args, timeout, log, stage):
        outcome, code = "spawn_failed", None
        self.last_error = ""
        with tempfile.TemporaryFile() as output:
            try:
                result = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
                code = result.returncode
                outcome = "ok" if code == 0 else "failed"
                if code:
                    raise RuntimeError(f"{stage} failed ({code}); see diagnostics.json")
            except subprocess.TimeoutExpired:
                outcome = "timeout"
                raise
            finally:
                try:
                    output.seek(0, 2)
                    output.seek(max(0, output.tell() - 4096))
                    excerpt = self.clean(output.read().decode("utf-8", errors="replace"))
                    self.last_error = excerpt if outcome != "ok" else ""
                    # Persist only a bounded redacted tail, never raw build output.
                    try:
                        log.write_text(excerpt)
                        os.chmod(log, 0o600)
                    except OSError:
                        pass
                    self.record(stage, outcome=outcome, exit_code=code,
                                output_excerpt=self.last_error)
                except Exception as error:
                    print(f"Diagnostic capture unavailable: {type(error).__name__}", file=sys.stderr)
