#!/usr/bin/python3
"""Offline policy/preflight tests; CI runs these without touching the host."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("install_policy", ROOT / "scripts/install-policy.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


def release(tag, **kwargs):
    return {"tag_name": tag, "draft": False, "prerelease": False, "assets": [], **kwargs}


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        self.env = patch.dict(os.environ, {"HOME": str(self.home), "NO_COLOR": "1"})
        self.env.start()
        self.addCleanup(self.env.stop)
        policy.fetch.cache_clear()

    def entry(self, ident="core.github_cli", requested="2.0.0", current="1.9.0"):
        return {"id": ident, "requested": requested, "commands": ["gh"],
                "current": current, "target": requested, "policy": "same-major", "path": "/test/gh"}

    def test_exact_rolling_allowlist(self):
        self.assertEqual(policy.ROLLING, {"core.github_cli", "cloud.aws_cli", "cloud.gcloud",
                                         "cloud.helm", "cloud.terraform", "cloud.azure_cli", "cloud.cloudflared"})
        self.assertNotIn("cloud.kubectl", policy.ROLLING)

    def test_stable_rejects_prereleases_and_drafts(self):
        for item in [release("v3.0.0-rc1"), release("v3.0.0", draft=True), release("v3.0.0", prerelease=True)]:
            self.assertEqual(policy.release_version(item), "")
        self.assertEqual(policy.release_version(release("azure-cli-2.99.0")), "2.99.0")
        self.assertGreater(policy.order("25.0.4.1+2"), policy.order("25.0.4.1+1"))

    def test_major_boundary_searches_maintained_series(self):
        def get(url):
            if url.endswith("/latest"):
                return release("v3.0.0")
            return [release("v3.0.0"), release("v2.9.0"), release("v2.10.0"), release("v2.99.0-rc1")]
        with patch.object(policy, "get_json", side_effect=get):
            self.assertEqual(policy.github("cli/cli", 2)[0], "2.10.0")
        with patch.object(policy, "get_json", side_effect=[release("v3.0.0"), []]):
            with self.assertRaisesRegex(ValueError, "major 2"):
                policy.github("cli/cli", 2)

    def test_digest_from_selected_release_not_repository_pin(self):
        entry = self.entry(requested="2.10.0")
        entry["target"] = "2.10.0"
        item = release("v2.10.0", assets=[{"name": "gh_2.10.0_linux_arm64.tar.gz", "digest": "sha256:" + "a" * 64}])
        self.assertEqual(policy.integrity(entry, item, "arm64"), "sha256:" + "a" * 64)
        with patch.object(policy, "fetch", return_value="b" * 64 + "  gh_2.10.0_linux_arm64.tar.gz\n"):
            self.assertEqual(policy.integrity(entry, release("v2.10.0"), "arm64"), "sha256:" + "b" * 64)
        with self.assertRaises(ValueError):
            policy.integrity({"id": "cloud.cloudflared", "target": "2026.9.0"}, {}, "amd64")
        with self.assertRaises(ValueError):
            policy.checksum("a" * 64 + "  other-file", "target-file")

    def test_resolve_same_major_but_report_new_major(self):
        entry = self.entry()
        observed = (entry["id"], {"path": "/test/gh", "version": "2.0.0"})
        with patch.object(policy.software, "probe", return_value=observed), \
                patch.object(policy, "upstream", side_effect=[("3.0.0", {}), ("2.10.0", {})]), \
                patch.object(policy, "integrity", return_value="sha256:" + "a" * 64):
            result = policy.resolve(entry, {}, "amd64")
        self.assertEqual((result["target"], result["latest"]), ("2.10.0", "3.0.0"))

    def test_cannot_silently_fall_back_after_resolution_failure(self):
        observed = ("core.github_cli", {"version": "2.0.0", "path": "/test/gh"})
        with patch.object(policy.software, "probe", return_value=observed), \
                patch.object(policy, "upstream", side_effect=ValueError("API rate limit")):
            result = policy.resolve(self.entry(), {}, "amd64")
        self.assertIn("API rate limit", result["error"])
        entry = self.entry("languages.node", "26.0.0")
        with patch.object(policy.software, "probe", return_value=observed), \
                patch.object(policy, "upstream", side_effect=ValueError("offline")):
            result = policy.resolve(entry, {}, "amd64")
        self.assertNotIn("error", result)
        self.assertEqual(result["target"], "26.0.0")
        self.assertIn("resolution_warning", result)

    def test_repo_baseline_never_regresses(self):
        with patch.object(policy.software, "probe", return_value=("gh", {"version": None, "path": None})), \
                patch.object(policy, "upstream", side_effect=[("2.0.0", {}), ("2.0.0", {})]):
            result = policy.resolve(self.entry(requested="2.10.0"), {}, "amd64")
        self.assertIn("older than", result["error"])

    def test_report_high_low_current_and_unknown_are_nonfatal(self):
        for current, latest, expected in [("2.0.0", "3.0.0", "high"), ("2.0.0", "2.1.0", "low"),
                                           ("3.0.0", "3.0.0", None), ("4.0.0", "3.0.0", None), (None, "3.0.0", "warn")]:
            entry = {**self.entry(), "latest": latest}
            with patch.object(policy.software, "probe", return_value=("gh", {"version": current})), \
                    contextlib.redirect_stdout(io.StringIO()):
                result = policy.report([entry])
            self.assertEqual(result[0]["severity"] if result else None, expected)

    def test_colors_and_events_are_capability_aware(self):
        output = io.StringIO()
        with patch.dict(os.environ, {"NO_COLOR": "", "DOTFILES_COLOR_ACTIVE": "true", "DOTFILES_COLOR": "always"}), \
                contextlib.redirect_stdout(output):
            policy.say("LOW", "minor")
            policy.say("HIGH", "major")
        self.assertIn("\033[33m", output.getvalue())
        self.assertIn("\033[31m", output.getvalue())
        output = io.StringIO()
        event = self.home / "events.jsonl"
        with patch.dict(os.environ, {"NO_COLOR": "1", "DOTFILES_EVENT_LOG": str(event)}), \
                contextlib.redirect_stdout(output):
            policy.say("HIGH", "major")
        self.assertNotIn("\033", output.getvalue())
        self.assertEqual(json.loads(event.read_text())["level"], "high")

    def test_selector_isolation_and_kubectl_stays_pinned(self):
        entries = policy.selected(ROOT, ["core"])
        self.assertEqual([entry["id"] for entry in entries], ["core.github_cli"])
        self.assertEqual(policy.selected(ROOT, ["detect"]), [])
        with self.assertRaises(ValueError):
            policy.selected(ROOT, ["not-a-section"])
        kubectl = next(entry for entry in policy.selected(ROOT, ["cloud"]) if entry["id"] == "cloud.kubectl")
        with patch.object(policy.software, "probe", return_value=("kubectl", {"version": "1.37.1", "path": "/test/kubectl"})), \
                patch.object(policy, "upstream", return_value=("1.38.0", {})):
            result = policy.resolve(kubectl, {}, "amd64")
        self.assertEqual(result["target"], kubectl["requested"])
        self.assertEqual(result["policy"], "repo-minimum")

    def test_gcloud_installed_major_is_not_crossed(self):
        entry = self.entry("cloud.gcloud", "distro", "578.0.1")
        with patch.object(policy, "get_json", return_value={"version": "600.0.0"}), \
                patch.object(policy.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "google-cloud-cli | 578.0.2-0 | signed repo\ngoogle-cloud-cli | 600.0.0-0 | repo\n", "")):
            self.assertEqual(policy.upstream(entry, {}, 578)[0], "578.0.2")
            self.assertEqual(policy.upstream(entry, {})[0], "600.0.0")

    def test_atomic_private_plan_and_redirect_refusal(self):
        path = self.home / "run/versions.json"
        policy.atomic_json(path, {"target": "2.0.0"})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        redirected = self.home / "redirect"
        redirected.symlink_to(path.parent)
        with self.assertRaisesRegex(ValueError, "redirected"):
            policy.atomic_json(redirected / "versions.json", {})

    def test_resume_does_not_reresolve_or_rewrite_plan(self):
        plan = self.home / "versions.json"
        data = {"schema": 1, "source": str(ROOT), "sections": ["core"], "tools": {}}
        policy.atomic_json(plan, data)
        original = plan.read_bytes()
        args = ["policy", "preflight", "--source", str(ROOT), "--sections", "core", "--plan", str(plan), "--resume"]
        with patch.object(sys, "argv", args), patch.object(policy, "host_checks", return_value=[]), \
                patch.object(policy, "resolve", side_effect=AssertionError("network used on resume")), \
                contextlib.redirect_stdout(io.StringIO()):
            policy.main()
        self.assertEqual(plan.read_bytes(), original)
        data["sections"] = ["cloud"]
        policy.atomic_json(plan, data)
        with patch.object(sys, "argv", args), patch.object(policy, "host_checks", return_value=[]):
            with self.assertRaisesRegex(ValueError, "inputs changed"):
                policy.main()

    def test_standalone_preflight_does_not_write_state(self):
        args = ["policy", "preflight", "--source", str(ROOT), "--sections", "detect", "--json"]
        before = sorted(self.home.rglob("*"))
        with patch.object(sys, "argv", args), patch.object(policy, "host_checks", return_value=[]), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            policy.main()
        self.assertEqual(sorted(self.home.rglob("*")), before)
        self.assertEqual(json.loads(output.getvalue())["tools"], {})

    def test_health_blocker_prevents_plan_publication(self):
        plan = self.home / "versions.json"
        args = ["policy", "preflight", "--sections", "detect", "--plan", str(plan), "--json"]
        with patch.object(sys, "argv", args), patch.object(policy, "host_checks", return_value=[("FAIL", "disk full")]), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                policy.main()
        self.assertEqual(error.exception.code, 1)
        self.assertFalse(plan.exists())

    def test_fetch_is_bounded_does_not_leak_tokens(self):
        with patch.dict(os.environ, {"GH_TOKEN": "synthetic-test-only"}), \
                patch.object(policy.subprocess, "run", return_value=subprocess.CompletedProcess([], 22, b"", b"sensitive")) as run:
            with self.assertRaisesRegex(ValueError, "API rate limits") as error:
                policy.fetch("https://api.github.com/repos/cli/cli/releases/latest")
        self.assertNotIn("sensitive", str(error.exception))
        self.assertIn("--max-time", run.call_args.args[0])
        self.assertEqual(run.call_args.kwargs["timeout"], 100)
        with patch.object(policy.subprocess, "run", side_effect=subprocess.TimeoutExpired(["Authorization: Bearer synthetic"], 100)):
            with self.assertRaisesRegex(ValueError, "timed out") as error:
                policy.fetch("https://api.github.com/repos/cli/cli/releases/latest")
        self.assertNotIn("synthetic", str(error.exception))


if __name__ == "__main__":
    unittest.main()
