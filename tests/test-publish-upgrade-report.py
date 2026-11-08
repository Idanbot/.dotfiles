#!/usr/bin/python3
"""Mock GH publication so weekly advisories do not create per-tool noise."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("publisher", ROOT / "scripts/publish-upgrade-report.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublisherTests(unittest.TestCase):
    def test_create_once_then_edit_without_comments(self):
        for issues, action in [([], "create"), ([{"number": 42, "title": publisher.TITLE}], "edit")]:
            with patch.object(publisher.subprocess, "run", side_effect=[
                subprocess.CompletedProcess([], 0, json.dumps(issues)),
                subprocess.CompletedProcess([], 0, "url")]) as run:
                publisher.publish(Path("report.md"), "owner/repo")
            args = run.call_args.args[0]
            self.assertEqual(args[:3], ["gh", "issue", action])
            self.assertIn("--body-file", args)
            self.assertNotIn("comment", args)

    def test_ambiguous_issue_is_rejected(self):
        issues = [{"number": n, "title": publisher.TITLE} for n in (1, 2)]
        with patch.object(publisher.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(issues))):
            with self.assertRaisesRegex(ValueError, "Multiple"):
                publisher.publish(Path("report.md"), "owner/repo")

    def test_publication_failure_is_not_suppressed(self):
        with patch.object(publisher.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["gh"])):
            with self.assertRaises(subprocess.CalledProcessError):
                publisher.publish(Path("report.md"), "owner/repo")


class MaintenanceTests(unittest.TestCase):
    def run_audit(self, mode="weekly", failure="", publish=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "scripts").mkdir()
            python = root / "bin/python3"
            python.write_text('''#!/bin/bash
case "$1" in
  scripts/install-policy.py) label=recommendations ;;
  scripts/audit-vulnerabilities.py) label=vulnerabilities ;;
  scripts/publish-upgrade-report.py) cp "$2" published.md; exit ;;
  *) exit 99 ;;
esac
if [[ "$MOCK_FAILURE" == "$label" ]]; then
  printf 'PARTIAL-UNTRUSTED-OUTPUT\\n'
  exit 23
fi
printf '\\n## Fresh %s\\n' "$label"
''')
            python.chmod(0o755)
            updater = root / "scripts/update-packages.sh"
            updater.write_text('''#!/bin/bash
if [[ "$MOCK_FAILURE" == upgrades ]]; then
  printf 'PARTIAL-UNTRUSTED-OUTPUT\\n' >"$3"
  exit 23
fi
printf '## Fresh upgrades (current manifest only)\\n' >"$3"
''')
            updater.chmod(0o755)
            report = root / "report.md"
            report.write_text("STALE-REMOVED-TOOL\n")
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/ci/maintenance-audit.sh"), mode, str(report)]
                + ([] if publish else ["--no-publish"]),
                cwd=root, env={**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}",
                               "MOCK_FAILURE": failure, "GITHUB_STEP_SUMMARY": str(root / "summary")},
                capture_output=True, text=True, timeout=10,
            )
            body = report.read_text()
            published = (root / "published.md")
            self.assertNotIn("STALE-REMOVED-TOOL", body)
            self.assertNotIn("PARTIAL-UNTRUSTED-OUTPUT", body)
            self.assertIn("Generated (UTC):", body)
            self.assertIn("Source revision:", body)
            if mode == "weekly" and publish:
                self.assertEqual(published.read_text(), body)
            else:
                self.assertFalse(published.exists())
            return result, body

    def test_success_replaces_obsolete_entries(self):
        result, body = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("**Status: complete**", body)
        for label in ("upgrades", "recommendations", "vulnerabilities"):
            self.assertIn(f"## Fresh {label}", body)

    def test_failures_publish_incomplete_status_and_fail_the_job(self):
        for failure in ("upgrades", "recommendations", "vulnerabilities"):
            with self.subTest(failure=failure):
                result, body = self.run_audit(failure=failure)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("**Status: incomplete**", body)
                self.assertIn("No current results", body)

    def test_daily_report_never_replaces_combined_weekly_issue(self):
        result, body = self.run_audit(mode="daily")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Fresh upgrades", body)
        self.assertIn("Fresh vulnerabilities", body)

    def test_weekly_preview_does_not_publish(self):
        result, body = self.run_audit(publish=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Fresh upgrades", body)


if __name__ == "__main__":
    unittest.main()
