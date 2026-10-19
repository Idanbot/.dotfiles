#!/usr/bin/env python3
"""The registry must account for every entrypoint, including explicit exceptions."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = (
    Path(sys.argv.pop(1)).resolve()
    if len(sys.argv) > 1
    else Path(__file__).resolve().parents[1]
)
spec = importlib.util.spec_from_file_location(
    "suite_runner", ROOT / "scripts/ci/run-tests.py"
)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RegistryTests(unittest.TestCase):
    def test_real_registry_is_complete(self):
        data = runner.registry(ROOT)
        self.assertGreaterEqual(len(data["tests"]), 76)
        selectors = {
            entry["path"]
            for entry in data["tests"]
            if entry.get("suite") == "selectors"
        }
        self.assertIn("tests/test-install-options.sh", selectors)
        self.assertIn("tests/test-install-selector-profile.sh", selectors)

    def test_unregistered_stale_duplicate_and_invalid_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tests").mkdir()
            test = root / "tests/test-one.sh"
            test.touch()
            entry = {
                "path": "tests/test-one.sh",
                "kind": "suite",
                "suite": "unit",
                "invocations": [[]],
            }
            data = {"suites": {"unit": {}}, "tests": [entry]}

            def write():
                (root / "tests/suites.json").write_text(json.dumps(data))

            write()
            runner.registry(root)
            (root / "tests/test-forgotten.py").touch()
            with self.assertRaisesRegex(ValueError, "unregistered"):
                runner.registry(root)
            (root / "tests/test-forgotten.py").unlink()
            data["tests"].append(entry)
            write()
            with self.assertRaisesRegex(ValueError, "duplicate"):
                runner.registry(root)
            data["tests"].pop()
            entry["suite"] = "absent"
            write()
            with self.assertRaisesRegex(ValueError, "unknown suite"):
                runner.registry(root)
            entry.update(
                kind="manual",
                command="bash tests/test-one.sh",
                reason="live",
                covered_by=[],
            )
            write()
            with self.assertRaisesRegex(ValueError, "missing caller"):
                runner.registry(root)
            test.unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                runner.registry(root)

    def test_suite_failure_is_not_swallowed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tests").mkdir()
            (root / "tests/test-one.sh").write_text("exit 19\n")
            (root / "tests/test-two.sh").write_text("echo second-test-ran\n")
            (root / "tests/suites.json").write_text(
                json.dumps(
                    {
                        "suites": {"unit": {}},
                        "tests": [
                            {
                                "path": "tests/test-one.sh",
                                "kind": "suite",
                                "suite": "unit",
                                "invocations": [[]],
                            },
                            {
                                "path": "tests/test-two.sh",
                                "kind": "suite",
                                "suite": "unit",
                                "invocations": [[]],
                            },
                        ],
                    }
                )
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/ci/run-tests.py"),
                    "--root",
                    str(root),
                    "--output",
                    str(root / "results"),
                    "unit",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("19", completed.stderr)
            self.assertIn("second-test-ran", completed.stdout)
            report = json.loads((root / "results/results.json").read_text())
            self.assertEqual(report["status"], "failure")
            self.assertEqual([item["exit_code"] for item in report["results"]], [19, 0])
            self.assertTrue(
                all(item["duration_seconds"] >= 0 for item in report["results"])
            )
            self.assertTrue((root / "results/junit.xml").exists())


if __name__ == "__main__":
    unittest.main()
