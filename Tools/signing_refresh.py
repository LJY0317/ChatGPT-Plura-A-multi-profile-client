"""Project-owned Personal Team refresh; only Apple tools perform signing/install."""
import argparse
import datetime as dt
import fcntl
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys

from refresh_diagnostics import Diagnostics

UTC = dt.timezone.utc
WINDOW = dt.timedelta(days=3)


def read_json(path, default):
    return json.loads(path.read_text()) if path.exists() else default


def save_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def profile(app):
    path = app / "embedded.mobileprovision"
    if not path.exists():
        return None
    result = subprocess.run(["security", "cms", "-D", "-i", str(path)],
                            capture_output=True, check=True)
    data = plistlib.loads(result.stdout)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    return {"expires": data["ExpirationDate"].replace(tzinfo=UTC),
            "bundle_id": info["CFBundleIdentifier"],
            "teams": data.get("TeamIdentifier", [])}


def extends(expires, previous, now):
    return expires is not None and expires > now and (not previous or expires > dt.datetime.fromisoformat(previous))


def classify(stage, message):
    text = message.lower()
    if "no accounts" in text:
        return "Xcode에 서명용 Apple 계정이 없습니다."
    if any(word in text for word in ("authentication", "session has expired", "credentials", "login failed")):
        return "Xcode의 Apple 계정 인증을 확인하세요."
    if any(word in text for word in ("locked", "unlock")):
        return "기기를 잠금 해제한 뒤 다시 연결하세요."
    if stage.startswith("install"):
        return "기기 연결·신뢰·개발자 모드를 확인하세요."
    return "Xcode 빌드·프로파일 발급 오류입니다. 진단 기록을 확인하세요."


class Refresh:
    def __init__(self, root, spec):
        self.root, self.spec = pathlib.Path(root), spec
        self.support = pathlib.Path.home() / "Library/Application Support" / spec["support"]
        self.config_path = self.support / "config.json"
        self.state_path = self.support / "state.json"
        self.source = self.support / "Source"
        self.derived = self.support / "DerivedData"
        self.app = self.derived / "Build/Products/Debug-iphoneos" / spec["app"]
        self.diag = Diagnostics(self.support)

    def snapshot(self):
        # One replaceable source snapshot. Automatic renewal never reads live sources.
        paths = subprocess.check_output(["git", "-C", str(self.root), "ls-files", "-z",
                                         "--", *self.spec["sources"]]).split(b"\0")
        temporary = self.support / "Source.next"
        if temporary.exists():
            shutil.rmtree(temporary)
        temporary.mkdir()
        for raw in paths:
            if not raw:
                continue
            relative = pathlib.Path(os.fsdecode(raw))
            original, target = self.root / relative, temporary / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if original.is_symlink():
                target.symlink_to(os.readlink(original))
            else:
                shutil.copy2(original, target)
        if self.source.exists():
            shutil.rmtree(self.source)
        temporary.replace(self.source)
        revision = subprocess.check_output(["git", "-C", str(self.root), "rev-parse", "HEAD"], text=True).strip()
        dirty = bool(subprocess.check_output(["git", "-C", str(self.root), "diff", "HEAD", "--", *self.spec["sources"]]))
        save_json(self.support / "source.json", {"revision": revision, "modified_sources": dirty,
                  "registered_at": dt.datetime.now(UTC).isoformat()})

    def build(self, config):
        self.diag.command([
            "xcodebuild", "-quiet", "-project", str(self.source / self.spec["project"]),
            "-scheme", self.spec["scheme"], "-configuration", "Debug", "-sdk", "iphoneos",
            "-destination", "generic/platform=iOS", "-derivedDataPath", str(self.derived),
            "-allowProvisioningUpdates", "build", "CODE_SIGN_STYLE=Automatic",
            "DEVELOPMENT_TEAM=" + config["team"],
            "PRODUCT_BUNDLE_IDENTIFIER=" + config["bundle_id"]],
            900, self.support / "last-command.log", "build")

    def notify(self, state, issues, now):
        reason = "\n".join(sorted(set(issue["action"] for issue in issues)))
        if not reason:
            state.pop("notification", None)
            return
        previous = state.get("notification", {})
        if previous.get("reason") == reason and now - dt.datetime.fromisoformat(previous["time"]) < dt.timedelta(days=1):
            return
        script = "display notification " + json.dumps(reason, ensure_ascii=False) + " with title " + json.dumps(self.spec["name"] + " 자동 갱신 확인 필요", ensure_ascii=False)
        try:
            result = subprocess.run(["osascript", "-e", script], capture_output=True, timeout=10)
            if result.returncode == 0:
                state["notification"] = {"reason": reason, "time": now.isoformat()}
        except (OSError, subprocess.SubprocessError):
            pass

    def refresh(self, config, update=False):
        state = read_json(self.state_path, {"devices": {}})
        # Drop obsolete global waiting/cooldown flags; each device owns its expiry.
        state = {"devices": state.get("devices", {}), **({"notification": state["notification"]} if state.get("notification") else {})}
        now = dt.datetime.now(UTC)
        self.diag.configure(config)
        self.diag.observe()
        due = [device for device in config["devices"] if update or
               dt.datetime.fromisoformat(state["devices"].get(device, now.isoformat())) - now < WINDOW]
        self.diag.record("check", due_devices=len(due),
                         installed_expirations=[state["devices"].get(d) for d in config["devices"]])
        issues = []
        stage = "source"
        try:
            if update:
                self.snapshot()
            if due:
                if not self.source.exists():
                    raise RuntimeError("등록된 소스가 없습니다. --update로 사용할 버전을 등록하세요.")
                stage = "profile"
                current = profile(self.app)
                needs_build = update or not current or any(
                    not extends(current["expires"], state["devices"].get(d), now) for d in due)
                if needs_build:
                    stage = "build"
                    try:
                        self.build(config)
                    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                        issues.append({"stage": stage, "action": classify(stage, self.diag.last_error or str(error)),
                                       "error": self.diag.clean(str(error))})
                    current = None if update and issues else profile(self.app)
                stage = "identity"
                if current and (current["bundle_id"] != config["bundle_id"] or config["team"] not in current["teams"]):
                    raise RuntimeError("앱 식별자 또는 서명 팀이 등록 설정과 다릅니다.")
                stage = "profile"
                expires = current["expires"] if current else None
                self.diag.record("profile", expires=expires.isoformat() if expires else None)
                for index, device in enumerate(config["devices"], 1):
                    if device not in due:
                        continue
                    prior = state["devices"].get(device)
                    # Explicit version updates can reinstall a still-valid profile;
                    # scheduled refresh records success only for an actual extension.
                    usable = expires and expires > now and (update or extends(expires, prior, now))
                    if not usable:
                        issues.append({"stage": "profile", "device": index,
                                       "action": "새 서명 프로파일이 발급되지 않았습니다. 다음 예약 실행에서 재시도합니다."})
                        continue
                    stage = "install_device_" + str(index)
                    try:
                        self.diag.command(["xcrun", "devicectl", "device", "install", "app",
                                           "--device", device, "--timeout", "180", str(self.app)],
                                          210, self.support / "last-command.log", stage)
                        state["devices"][device] = expires.isoformat()
                        # Persist each successful device even if a later device fails.
                        save_json(self.state_path, state)
                        print(self.spec["name"] + ": device " + str(index) + " installed; signing expires " + expires.astimezone().isoformat())
                    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                        issues.append({"stage": stage, "device": index,
                                       "action": classify(stage, self.diag.last_error or str(error)),
                                       "error": self.diag.clean(str(error))})
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            issues.append({"stage": stage, "action": self.diag.clean(str(error))})
        result = {"time": dt.datetime.now(UTC).isoformat(),
                  "result": "pending" if issues else "refreshed" if due else "current", "issues": issues}
        self.diag.record("result", result=result["result"], issues=issues)
        # Account/build/source problems are actionable immediately. Disconnected
        # devices notify only as expiry approaches, so routine absence stays quiet.
        urgent = []
        for issue in issues:
            device_index = issue.get("device")
            if device_index and (issue["stage"] == "profile" or issue["stage"].startswith("install")):
                device = config["devices"][device_index - 1]
                installed = state["devices"].get(device)
                if installed and dt.datetime.fromisoformat(installed) - now >= dt.timedelta(days=1):
                    continue
            urgent.append(issue)
        self.notify(state, urgent, now)
        save_json(self.state_path, state)
        save_json(self.support / "last-run.json", result)
        for issue in issues:
            print(issue["action"], file=sys.stderr)
        return 1 if issues else 0

    def schedule(self, enabled):
        path = pathlib.Path.home() / "Library/LaunchAgents" / (self.spec["label"] + ".plist")
        domain = "gui/" + str(os.getuid())
        if path.exists():
            subprocess.run(["launchctl", "bootout", domain, str(path)], capture_output=True)
        if not enabled:
            path.unlink(missing_ok=True)
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        script = self.root / self.spec["entry"]
        data = {"Label": self.spec["label"], "ProgramArguments": ["/usr/bin/python3", str(script)],
                "EnvironmentVariables": {"PYTHONDONTWRITEBYTECODE": "1"},
                "RunAtLoad": True, "ProcessType": "Background", "LowPriorityIO": True,
                "StartCalendarInterval": [{"Hour": hour, "Minute": self.spec["minute"]} for hour in (0, 6, 12, 18)],
                "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"}
        path.write_bytes(plistlib.dumps(data))
        subprocess.run(["launchctl", "bootstrap", domain, str(path)], check=True)

    def main(self, argv=None):
        parser = argparse.ArgumentParser(description="Renew the registered app version using Xcode.")
        mode = parser.add_mutually_exclusive_group()
        mode.add_argument("--status", action="store_true")
        mode.add_argument("--update", action="store_true", help="Register current tracked source files, build and update configured devices.")
        mode.add_argument("--enable", action="store_true", help="Install this project's four-times-daily LaunchAgent.")
        mode.add_argument("--disable", action="store_true", help="Remove this project's LaunchAgent; preserve app data/configuration.")
        args = parser.parse_args(argv)
        if args.disable:
            self.schedule(False)
            return 0
        config = read_json(self.config_path, None)
        if args.status:
            print(json.dumps({"source": read_json(self.support / "source.json", None),
                              "state": read_json(self.state_path, None),
                              "last_run": read_json(self.support / "last-run.json", None)}, indent=2))
            return 0
        if not config:
            parser.error("Create private config.json as described in the project README.")
        os.umask(0o077)
        self.support.mkdir(parents=True, exist_ok=True)
        with (self.support / "refresh.lock").open("w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("A refresh is already running")
                return 0
            if not args.enable:
                return self.refresh(config, update=args.update)
        self.schedule(True)
        return 0


def entrypoint(root, spec):
    try:
        return Refresh(root, spec).main()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print("Refresh failed: " + str(error), file=sys.stderr)
        return 1
