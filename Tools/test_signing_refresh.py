import datetime as dt
import fcntl
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import signing_refresh as module

class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.job = module.Refresh(self.root, {
            "name": "Test", "support": "unused", "app": "Test.app",
            "project": "Test.xcodeproj", "scheme": "Test", "sources": ["Sources"]})
        self.job.support = self.root
        self.job.config_path = self.root / "config.json"
        self.job.state_path = self.root / "state.json"
        self.job.source = self.root / "Source"
        self.job.source.mkdir()
        self.job.diag = module.Diagnostics(self.root)
        self.config = {"devices": ["one", "two"], "team": "team", "bundle_id": "test"}
        self.now = dt.datetime.now(module.UTC)
        self.valid = self.now + dt.timedelta(days=2)
        self.prof = {"expires": self.valid, "bundle_id": "test", "teams": ["team"]}
        self.calls = []
        self.notifications = []
        self.patchers = [
            patch.object(self.job.diag, "observe"),
            patch.object(self.job.diag, "command", side_effect=lambda *a: self.calls.append(a)),
            patch.object(self.job, "notify", side_effect=lambda state, issues, now: self.notifications.extend(issues))]
        for p in self.patchers:
            p.start()
            self.addCleanup(p.stop)

    def state(self, first, second):
        module.save_json(self.job.state_path, {"devices": {"one": first, "two": second}})

    def test_profile_reuse_does_not_block_device_that_can_extend(self):
        prior = (self.now + dt.timedelta(days=1)).isoformat()
        other = self.valid.isoformat()
        self.state(prior, other)
        with patch.object(module, "profile", return_value=self.prof):
            code = self.job.refresh(self.config)
        installs = [a for a in self.calls if a[-1].startswith("install")]
        self.assertEqual([a[-1] for a in installs], ["install_device_1"])
        self.assertEqual(code, 1)
        self.assertEqual(module.read_json(self.job.state_path, {})["devices"]["one"], other)
        self.assertEqual(module.read_json(self.root / "last-run.json", {})["result"], "pending")

    def test_unchanged_profile_is_pending_not_success(self):
        prior = self.valid.isoformat()
        self.state(prior, prior)
        with patch.object(module, "profile", return_value=self.prof):
            self.assertEqual(self.job.refresh(self.config), 1)
        self.assertFalse(any(a[-1].startswith("install") for a in self.calls))
        self.assertEqual(module.read_json(self.job.state_path, {})["devices"]["one"], prior)

    def test_failed_update_never_installs_previous_binary(self):
        prior = (self.now - dt.timedelta(days=1)).isoformat()
        self.state(prior, prior)
        with patch.object(module, "profile", return_value=self.prof), \
             patch.object(self.job, "snapshot"), \
             patch.object(self.job, "build", side_effect=RuntimeError("build failed")):
            self.assertEqual(self.job.refresh(self.config, update=True), 1)
        self.assertFalse(self.calls)
        self.assertEqual(module.read_json(self.job.state_path, {})["devices"]["one"], prior)

    def test_failed_device_does_not_erase_other_device_success(self):
        prior = (self.now - dt.timedelta(days=1)).isoformat()
        self.state(prior, prior)
        def command(*args):
            if args[-1] == "install_device_2":
                raise RuntimeError("disconnected")
        with patch.object(module, "profile", return_value=self.prof), \
             patch.object(self.job.diag, "command", side_effect=command):
            self.assertEqual(self.job.refresh(self.config), 1)
        devices = module.read_json(self.job.state_path, {})["devices"]
        self.assertEqual(devices["one"], self.valid.isoformat())
        self.assertEqual(devices["two"], prior)

    def test_account_failure_notifies_without_waiting_for_expiry(self):
        prior = (self.now + dt.timedelta(days=2)).isoformat()
        self.state(prior, prior)
        self.job.diag.last_error = "No Accounts: Add a new account"
        with patch.object(module, "profile", return_value=None), \
             patch.object(self.job, "build", side_effect=RuntimeError("failed")):
            self.job.refresh(self.config)
        self.assertTrue(any("Apple 계정" in i["action"] for i in self.notifications))

    def test_current_devices_do_not_build_or_install(self):
        prior = (self.now + dt.timedelta(days=6)).isoformat()
        self.state(prior, prior)
        with patch.object(module, "profile", side_effect=AssertionError("should not inspect build")):
            self.assertEqual(self.job.refresh(self.config), 0)
        self.assertFalse(self.calls)

    def test_active_lock_does_not_overwrite_last_result(self):
        self.job.config_path.write_text(json.dumps(self.config))
        last = self.root / "last-run.json"
        last.write_text('{"result":"pending"}')
        with (self.root / "refresh.lock").open("w") as locked:
            fcntl.flock(locked, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.job.main([]), 0)
        self.assertEqual(last.read_text(), '{"result":"pending"}')


    def test_registered_snapshot_is_independent_of_live_sources(self):
        import subprocess
        source = self.root / "Sources"
        source.mkdir()
        (source / "App.swift").write_text("registered")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "add", "Sources"], check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Test",
                        "-c", "user.email=test@example.invalid", "commit", "-qm", "test"], check=True)
        self.job.snapshot()
        (source / "App.swift").write_text("unreleased")
        self.assertEqual((self.job.source / "Sources/App.swift").read_text(), "registered")
        self.job.build(self.config)
        self.assertIn(str(self.job.source / "Test.xcodeproj"), self.calls[-1][0])

if __name__ == "__main__":
    unittest.main()
