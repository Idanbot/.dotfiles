#!/usr/bin/python3
"""Mock GH publication so weekly advisories do not create per-tool noise."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
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


if __name__ == "__main__":
    unittest.main()
