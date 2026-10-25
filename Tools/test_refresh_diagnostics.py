import datetime as dt
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import refresh_diagnostics as module


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.diag = module.Diagnostics(self.root)

    def events(self):
        return json.loads(self.diag.path.read_text())["events"]

    def test_recurrence_and_environment_transition(self):
        self.diag.context = {"account_count_hint": 1}
        self.diag.record("environment")
        self.diag.record("build", outcome="failed")
        self.diag.record("environment")
        self.assertEqual(len(self.events()), 2)
        self.assertEqual(self.events()[-1]["count"], 2)
        self.diag.context = {"account_count_hint": 0}
        self.diag.record("environment")
        self.assertEqual(len(self.events()), 3)
        self.assertEqual(self.events()[-1]["details"]["environment"]["account_count_hint"], 0)
        self.assertEqual(self.diag.path.stat().st_mode & 0o777, 0o600)

    def test_retention_by_age_and_bytes(self):
        old = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=31)).isoformat()
        self.diag.path.write_text(json.dumps({"events": [
            {"first_seen": old, "last_seen": old, "count": 1,
             "details": {"stage": "old"}}]}))
        with patch.object(module, "MAX_BYTES", 1500):
            for i in range(6):
                self.diag.record("build", outcome=str(i), output_excerpt="x" * 400)
        self.assertLessEqual(self.diag.path.stat().st_size, 1500)
        self.assertFalse(any(e["details"]["stage"] == "old" for e in self.events()))

    def test_many_small_events_are_not_evicted_by_count(self):
        for i in range(125):
            self.diag.record("small", outcome=str(i))
        self.assertEqual(len(self.events()), 125)

    def test_command_failures_survive_next_command_and_redact(self):
        self.diag.configure({"devices": ["My iPhone"], "team": "MYTEAM"})
        message = "My iPhone MYTEAM person@example.com token=abc123"
        with self.assertRaises(RuntimeError):
            self.diag.command([sys.executable, "-c", f"print({message!r}); raise SystemExit(65)"],
                              10, self.root / "last-command.log", "build")
        self.diag.command([sys.executable, "-c", "pass"], 10,
                          self.root / "last-command.log", "install_device_1")
        event = self.events()[0]["details"]
        self.assertEqual(event["exit_code"], 65)
        for value in ["My iPhone", "MYTEAM", "person@example.com", "abc123"]:
            self.assertNotIn(value, event["output_excerpt"])
        self.assertEqual(len(self.events()), 2)

    def test_timeout_and_unwritable_diagnostics_preserve_command_result(self):
        with patch.object(module.subprocess, "run", side_effect=subprocess.TimeoutExpired("test", 1)):
            with self.assertRaises(subprocess.TimeoutExpired):
                self.diag.command(["test"], 1, self.root / "last-command.log", "build")
        self.assertEqual(self.events()[0]["details"]["outcome"], "timeout")
        self.diag.path = self.root / "missing" / "diagnostics.json"
        self.diag.command([sys.executable, "-c", "pass"], 10,
                          self.root / "last-command.log", "build")

    def test_observation_failure_does_not_block_refresh(self):
        with patch.object(self.diag, "_observe", side_effect=ValueError("bad preferences")):
            self.diag.observe()
        self.assertEqual(self.events()[0]["details"]["environment"],
                         {"observation_error": "ValueError"})



if __name__ == "__main__":
    unittest.main()
