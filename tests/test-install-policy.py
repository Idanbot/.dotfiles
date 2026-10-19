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
        observed = ("core.github_cli", {"version": "1.9.0", "path": "/test/gh"})
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

    def test_optional_freshness_outage_preserves_satisfying_install(self):
        observed = ("gh", {"version": "2.0.0", "path": "/test/gh"})
        with patch.object(policy.software, "probe", return_value=observed), \
                patch.object(policy, "upstream", side_effect=ValueError("offline")):
            result = policy.resolve(self.entry(), {}, "amd64")
        self.assertNotIn("error", result)
        self.assertEqual(result["target"], "2.0.0")
        self.assertIn("offline", result["resolution_warning"])

    def test_unknown_version_is_not_missing(self):
        entry = {**self.entry(), "current": "", "probe": "timeout"}
        self.assertEqual(policy.version_label(entry), "version unknown (probe: timeout)")
        entry["path"] = None
        self.assertEqual(policy.version_label(entry), "missing")

    def test_unknown_active_version_preserved_even_when_digest_owned(self):
        for current in ("", "unparseable"):
            with self.subTest(current=current), \
                    patch.dict(os.environ, {"DOTFILES_REPLACE_BINARIES": ""}), \
                    patch.object(policy, "ownership_status", return_value="verified-dotfiles") as owned:
                action, ownership = policy.planned_action(self.entry(current=current))
            self.assertIn("preserve active executable with unknown version", action)
            self.assertEqual(ownership, "unknown-version")
            owned.assert_not_called()
        missing = {**self.entry(current=""), "path": None}
        self.assertEqual(policy.planned_action(missing), ("install", "missing"))

    def test_only_explicitly_named_replacement_overrides_unknown_preservation(self):
        for replacement, expected in (("gh", "explicit-replacement"),
                                      ("node,gh", "explicit-replacement"),
                                      ("github_cli", "unknown-version"),
                                      ("other", "unknown-version")):
            with self.subTest(replacement=replacement), \
                    patch.dict(os.environ, {"DOTFILES_REPLACE_BINARIES": replacement}):
                self.assertEqual(policy.planned_action(self.entry(current=""))[1], expected)

    def test_preflight_warns_when_preserving_unknown_active_version(self):
        args = ["policy", "preflight", "--source", str(ROOT), "--sections", "core", "--json"]
        with patch.object(sys, "argv", args), patch.object(policy, "host_checks", return_value=[]), \
                patch.object(policy, "selected", return_value=[self.entry()]), \
                patch.object(policy, "resolve", return_value=self.entry(current="")), \
                patch.dict(os.environ, {"DOTFILES_REPLACE_BINARIES": ""}), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            policy.main()
        plan = json.loads(output.getvalue())
        self.assertEqual(plan["tools"]["core.github_cli"]["ownership"], "unknown-version")
        self.assertTrue(any(level == "WARN" and "unknown version" in message
                            for level, message in plan["checks"]))

    def test_legacy_and_modified_ownership_are_not_claimed_as_managed(self):
        binary = self.home / "tool"
        binary.write_text("original")
        state = self.home / "state"
        state.mkdir()
        (state / "installed.tsv").write_text(f"tool\t1.0.0\tgithub\t{binary}\n")
        self.assertEqual(policy.ownership_status(str(binary), state), "legacy-no-stamp")
        stamps = state / "ownership"
        stamps.mkdir()
        (stamps / (policy.hashlib.sha256(str(binary).encode()).hexdigest() + ".sha256")).write_text("incorrect")
        self.assertEqual(policy.ownership_status(str(binary), state), "modified-or-unverifiable")
        subprocess.run(["bash", "-c", 'source "$1/scripts/lib.sh"; record_install tool 1.0.0 fixture "$2"',
                        "record-fixture", str(ROOT), str(binary)], check=True, capture_output=True,
                       env={**os.environ, "DOTFILES_SOURCE_DIR": str(ROOT), "DOTFILES_STATE_DIR": str(state)})
        self.assertEqual(policy.ownership_status(str(binary), state), "verified-dotfiles")
        binary.write_text("locally modified")
        self.assertEqual(policy.ownership_status(str(binary), state), "modified-or-unverifiable")

    def test_platform_and_side_by_side_routing(self):
        with patch.dict(os.environ, {"DOTFILES_WSL": "true"}):
            entries = policy.selected(ROOT, ["media", "desktop", "languages"])
        self.assertTrue(entries)
        self.assertFalse(any(entry["id"].startswith("media.") or entry["id"] == "terminal.kitty" for entry in entries))
        self.assertIn("~/.fzf", policy.planned_action(self.entry("core.fzf"))[0])
        self.assertIn("private uv", policy.planned_action(self.entry("languages.python"))[0])

    def test_failed_integrity_resolution_never_leaves_unverified_target(self):
        observed = ("gh", {"version": "2.0.0", "path": "/test/gh"})
        with patch.object(policy.software, "probe", return_value=observed), \
                patch.object(policy, "upstream", return_value=("2.9.0", {})), \
                patch.object(policy, "integrity", side_effect=ValueError("no digest")):
            result = policy.resolve(self.entry(), {}, "amd64")
        self.assertEqual(result["target"], "2.0.0")
        self.assertNotIn("integrity", result)
        self.assertNotIn("error", result)

    def test_compatibility_lines_and_package_manager_majors(self):
        with patch.object(policy, "get_json", return_value=[{"version": "v26.12.0"}, {"version": "v27.1.0"}, {"version": "v26.13.0-rc1"}]):
            self.assertEqual(policy.upgrade_candidate("languages.node", "26.5.0", "", {}), "26.12.0")
        with patch.object(policy, "get_json", return_value=[{"name": "v3.14.9"}, {"name": "v3.15.0"}]):
            self.assertEqual(policy.upgrade_candidate("languages.python", "3.14.8", "", {}), "3.14.9")
        with patch.object(policy, "get_json", return_value=[{"version": "go1.27.3", "stable": True}, {"version": "go1.28.0", "stable": True}]):
            self.assertEqual(policy.upgrade_candidate("languages.go", "1.27.2", "", {}), "1.27.3")
        with patch.object(policy, "upstream", return_value=("1.0.0", {})):
            self.assertEqual(policy.upgrade_candidate("languages.uv", "0.13.0", "", {}), "1.0.0")
        data = {"dist-tags": {"latest": "13.0.0"},
                "versions": {"12.3.0": {"engines": {"node": ">=26.0.0"}},
                             "13.0.0": {"engines": {"node": ">=27.0.0"}}}}
        with patch.object(policy, "get_json", return_value=data):
            self.assertEqual(policy.upgrade_candidate("languages.npm", "12.0.1", "26.11.1", {}), "12.3.0")
        self.assertTrue(policy.node_engine_matches("26.1.0", "^24.0.0 || >=26.0.0"))
        self.assertFalse(policy.node_engine_matches("26.1.0", "unrecognized-engine"))

    def test_npm_candidates_obey_latest_ceiling_and_node_for_all_packages(self):
        data = {"dist-tags": {"latest": "2.0.0"}, "versions": {
            "1.0.0": {},
            "1.5.0": {"engines": {"node": ">=26"}},
            "2.0.0": {"engines": {"node": ">=27"}},
            "2.1.0": {"engines": {"node": ">=26"}},
            "3.0.0-rc.1": {},
        }}
        with patch.object(policy, "get_json", return_value=data) as get:
            candidate = policy.upgrade_candidate(
                "ai_tools.demo", "1.0.0", "26.11.1", {"source": "npm", "package": "@scope/demo"})
        self.assertEqual(candidate, "1.5.0")
        self.assertEqual(get.call_args.args[0], "https://registry.npmjs.org/@scope%2Fdemo")
        with patch.object(policy, "get_json", return_value=data):
            self.assertEqual(policy.upstream(self.entry("ai_tools.demo"),
                                            {"source": "npm", "package": "demo"})[0], "2.0.0")

    def test_npm_missing_or_unstable_latest_fails_closed(self):
        for tags in ({}, {"latest": "2.0.0-rc.1"}):
            with self.subTest(tags=tags), patch.object(policy, "get_json", return_value={
                    "dist-tags": tags, "versions": {"1.1.0": {}}}):
                with self.assertRaisesRegex(ValueError, "npm latest"):
                    policy.upgrade_candidate("languages.npm", "1.0.0", "26.0.0", {})

    def test_candidate_cli_passes_node_pin_for_npm_tools(self):
        args = ["policy", "candidate", "--source", str(ROOT), "--tool", "languages.typescript"]
        node = policy.load_versions(ROOT / "packages.yaml")["languages"]["node"]
        with patch.object(sys, "argv", args), \
                patch.object(policy, "upgrade_candidate", return_value="7.0.3") as candidate, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            policy.main()
        self.assertEqual(candidate.call_args.args[2], node)
        self.assertEqual(output.getvalue(), "7.0.3\n")

    def test_pypi_candidates_skip_yanked_empty_and_prerelease_versions(self):
        data = {"info": {"version": "9.0.0"}, "releases": {
            "1.1.0": [{"yanked": False}],
            "1.2.0": [{"yanked": True}, {"yanked": False}],
            "2.0.0": [{"yanked": True}],
            "3.0.0": [],
            "4.0.0rc1": [{"yanked": False}],
        }}
        meta = {"source": "pypi", "package": "demo"}
        with patch.object(policy, "get_json", return_value=data):
            self.assertEqual(policy.upgrade_candidate("ai_tools.demo", "1.0.0", "", meta), "1.2.0")
            self.assertEqual(policy.upstream(self.entry("ai_tools.demo"), meta)[0], "1.2.0")
            self.assertEqual(policy.upgrade_candidate("ai_tools.demo", "1.3.0", "", meta), "1.3.0")

    def test_node_engine_ranges_reject_unsafe_caret_zero_major_matches(self):
        cases = [
            ("26.11.1", ">= 24 <27", True),
            ("26.11.1", "24.x || 26.x", True),
            ("26.11.1", "24 - 26", True),
            ("27.0.0", "24 - 26", False),
            ("0.2.5", "^0.2.3", True),
            ("0.3.0", "^0.2.3", False),
            ("0.0.4", "^0.0.3", False),
            ("26.11.1", ">=27.0.0", False),
            ("26.11.1", "~26.10.0", False),
            ("26.11.1", "26.11.*", True),
            ("26.11.1", ">=26 nonsense", False),
            ("", ">=0", False),
        ]
        for node, requirement, expected in cases:
            with self.subTest(node=node, requirement=requirement):
                self.assertEqual(policy.node_engine_matches(node, requirement), expected)

    def test_shared_policy_does_not_regress_or_cross_major_minor_lines(self):
        versions = ["1.2.4", "1.3.0", "2.0.0", "3.0.0-rc1"]
        self.assertEqual(policy.releases.latest_compatible(versions, "1.2.3", "minor"), "1.2.4")
        self.assertEqual(policy.releases.latest_compatible(versions, "1.2.3", "major"), "1.3.0")
        self.assertEqual(policy.releases.latest_compatible(versions, "1.2.3"), "2.0.0")
        self.assertEqual(policy.releases.latest_compatible(versions, "4.0.0"), "4.0.0")

    def test_global_recommendations_include_out_of_line_versions(self):
        with patch.object(policy.software, "catalog", return_value=[self.entry("languages.python", "3.14.8")]), \
                patch.object(policy, "upstream", return_value=("3.15.0", {})), \
                patch.object(policy, "upgrade_candidate", return_value="3.14.9"):
            report = policy.recommendations(ROOT)
        self.assertIn("3.14.8 | 3.14.9 | 3.15.0 | within policy: patch; newer minor line available", report)

    def test_java_recommendations_show_pinned_feature_release_and_new_major(self):
        with patch.object(policy.software, "catalog", return_value=[self.entry("languages.java", "25.0.4.1+1")]), \
                patch.object(policy, "upstream", return_value=("27.0.0+35", {})), \
                patch.object(policy, "upgrade_candidate", return_value="25.0.5+2"):
            report = policy.recommendations(ROOT)
        self.assertIn("25.0.4.1+1 | 25.0.5+2 | 27.0.0+35 | within policy: patch; newer major 27 available", report)
        self.assertIn("Latest compatible", report)

    def test_rust_and_cargo_advisories_use_toolchain_not_cargo_crate(self):
        manifest = '[pkg.cargo]\nversion = "0.100.0 (fixture)"\n[pkg.rust]\nversion = "1.99.0 (fixture)"\n'
        with patch.object(policy, "fetch", return_value=manifest):
            for ident in ("languages.rust", "languages.cargo"):
                self.assertEqual(policy.upstream(self.entry(ident), {})[0], "1.99.0")

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

    def test_aws_major_advisory_is_not_limited_to_v2_changelog(self):
        entry = self.entry("cloud.aws_cli", "2.37.12")
        with patch.object(policy, "get_json", return_value=[{"name": "3.0.0"}, {"name": "3.1.0-rc1"}, {"name": "2.40.0"}]), \
                patch.object(policy, "fetch", return_value="2.40.0\n======\n2.39.0\n"):
            self.assertEqual(policy.upstream(entry, {})[0], "3.0.0")
            self.assertEqual(policy.upstream(entry, {}, 2)[0], "2.40.0")

    def test_jdk_ga_major_only_release_name_is_normalized(self):
        data = [{"release_name": "jdk-27+35", "version": {"major": 27, "minor": 0, "security": 0, "build": 35}}]
        with patch.object(policy, "get_json", side_effect=[{"most_recent_feature_release": 27}, data]):
            latest = policy.upstream(self.entry("languages.java", "25.0.4.1+1"), {})[0]
        self.assertEqual(latest, "27.0.0+35")
        self.assertTrue(policy.stable(latest))

    def test_jdk_compatible_candidate_stays_on_pinned_feature_release(self):
        data = [
            {"release_name": "jdk-25.0.4.1+1"},
            {"release_name": "jdk-25.0.5+2"},
        ]
        with patch.object(policy, "get_json", return_value=data):
            candidate = policy.upgrade_candidate("languages.java", "25.0.4.1+1", "", {})
        self.assertEqual(candidate, "25.0.5+2")

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
