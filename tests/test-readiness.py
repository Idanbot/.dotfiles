#!/usr/bin/env python3
"""Synthetic, non-network capability tests; raw provider output must never escape."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("readiness", ROOT / "scripts/readiness.py")
readiness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(readiness)


class ReadinessTests(unittest.TestCase):
    def test_native_configuration_path_override_is_never_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "private-config"
            config.touch()
            with patch.dict(os.environ, {"AWS_CONFIG_FILE": str(config)}), \
                    patch.object(readiness.shutil, "which", return_value="/fixture/aws"):
                report = readiness.inspect(home="/nonexistent")
            aws = next(row for row in report["results"] if row["capability"] == "aws")
            self.assertTrue(aws["configured"])
            self.assertNotIn(directory, json.dumps(report))

    def test_default_never_executes_and_exposes_no_inventory(self):
        with tempfile.TemporaryDirectory() as home:
            config = Path(home) / ".aws/config"
            config.parent.mkdir()
            config.write_text("SYNTHETIC_SECRET account-123 project-private")
            with patch.object(readiness.shutil, "which", return_value="/private/user/bin/tool"), \
                    patch.object(readiness, "run_probe", side_effect=AssertionError("process launched")):
                report = readiness.inspect(home=home)
            aws = next(row for row in report["results"] if row["capability"] == "aws")
            self.assertEqual(aws["state"], "configured")
            self.assertEqual(aws["access"], "unverified")
            self.assertNotIn(home, json.dumps(report))
            self.assertNotIn("SYNTHETIC_SECRET", json.dumps(report))

    def test_absent_tools_do_not_fail_advisory_or_launch(self):
        with patch.object(readiness.shutil, "which", return_value=None), \
                patch.object(readiness, "run_probe", side_effect=AssertionError("launch")):
            report = readiness.inspect(True)
        self.assertTrue(report["advisory"])
        self.assertTrue(all(row["state"] == "unavailable" for row in report["results"]))

    def test_bounded_probes_classify_and_redact(self):
        for code, error, reason in [(0, "", "probe-succeeded"), (1, "denied", "denied"),
                                     (1, "expired", "expired"), (1, "error", "unknown")]:
            with self.subTest(reason=reason), \
                    patch.object(readiness.shutil, "which", return_value="/fixture/tool"), \
                    patch.object(readiness, "run_probe", return_value=subprocess.CompletedProcess(
                        [], code, b"SYNTHETIC_TOKEN account-123", f"{error} /private/user project-private".encode())) as run:
                report = readiness.inspect(True, home="/nonexistent", timeout=2)
                aws = next(row for row in report["results"] if row["capability"] == "aws")
                self.assertEqual(aws["reason"], reason)
                for call in run.call_args_list:
                    self.assertEqual(call.kwargs["timeout"], 2)
                for private in ("SYNTHETIC_TOKEN", "account-123", "/private/user", "project-private"):
                    self.assertNotIn(private, json.dumps(report))

    def test_timeout_and_missing_runtime_are_unknown_not_verified(self):
        for error, reason in [(subprocess.TimeoutExpired("fixture", 1), "timeout"), (OSError(), "unavailable")]:
            with patch.object(readiness.shutil, "which", return_value="/fixture/tool"), \
                    patch.object(readiness, "run_probe", side_effect=error):
                report = readiness.inspect(True)
            aws = next(row for row in report["results"] if row["capability"] == "aws")
            self.assertEqual(aws["reason"], reason)
            self.assertEqual(aws["access"], "unverified")

    def test_timeout_terminates_provider_children_holding_output_pipes(self):
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            readiness.run_probe([sys.executable, "-c",
                "import subprocess,time; subprocess.Popen(['sleep','60']); time.sleep(60)"],
                env=os.environ.copy(), timeout=0.1)
        self.assertLess(time.monotonic() - started, 3)


if __name__ == "__main__":
    unittest.main()
