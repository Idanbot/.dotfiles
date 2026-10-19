#!/usr/bin/env python3
"""Unit tests for the mocked, read-only pinned-version OSV audit."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "audit_vulnerabilities", ROOT / "scripts/audit-vulnerabilities.py")
audit_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit_module)


class VulnerabilityAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "packages.yaml").write_text(yaml.safe_dump({
            "core": {"gitleaks": "8.30.1", "gitleaks_alias": "8.30.1",
                     "jq": "distro"},
            "ai_tools": {"claude_cli": "2.1.296", "codex_cli": "standalone"},
        }))
        (self.root / "packages.meta.yaml").write_text(yaml.safe_dump({
            "core": {"gitleaks": {"source": "github", "repo": "gitleaks/gitleaks"},
                     "gitleaks_alias": {"source": "github", "repo": "gitleaks/gitleaks"},
                     "jq": {"source": "apt"}},
            "ai_tools": {
                "claude_cli": {"source": "npm", "package": "@anthropic-ai/claude-code"},
                "codex_cli": {"source": "install_script"},
            },
        }))

    def tearDown(self):
        self.temp.cleanup()

    def test_coordinates_cover_exact_pins_and_report_unmapped(self):
        scanned, skipped = audit_module.load_pins(self.root)
        self.assertEqual(len(scanned), 3)
        self.assertEqual(len(skipped), 2)
        npm = next(item for item in scanned if item["id"] == "ai_tools.claude_cli")
        self.assertEqual(npm["package"], {
            "ecosystem": "npm", "name": "@anthropic-ai/claude-code"})
        git = next(item for item in scanned if item["id"] == "core.gitleaks")
        self.assertEqual(git["version"], "v8.30.1")
        ast_grep = audit_module.coordinate(
            "core.ast_grep", "0.50.0",
            {"source": "github", "repo": "ast-grep/ast-grep"})
        self.assertEqual(ast_grep["version"], "0.50.0")

    def test_audit_deduplicates_coordinates_and_reports_fixed_release(self):
        requests = []

        def mocked_post(url, payload):
            requests.append((url, payload))
            return {"results": [
                {},
                {"vulns": [{"id": "GHSA-test-1234"}]},
            ]}

        vuln = {
            "id": "GHSA-test-1234",
            "aliases": ["CVE-2026-12345"],
            "summary": "Example vulnerability",
            "affected": [{"database_specific": {"severity": "HIGH"},
                          "ranges": [{"events": [
                              {"introduced": "0"}, {"fixed": "abcdef123456"}]}]}],
        }
        scanned, skipped, findings = audit_module.audit(
            self.root, request=mocked_post, fetch=lambda _: vuln,
            resolve_candidates=lambda *_: [])
        self.assertEqual(len(requests), 1)
        self.assertEqual(len(requests[0][1]["queries"]), 2)
        self.assertEqual(len(scanned), 3)
        self.assertEqual(len(skipped), 2)
        self.assertEqual(len(findings), 2)
        self.assertTrue(all(item["severity"] == "high" for item in findings))
        self.assertTrue(all(item["fixed"] == ["abcdef123456"] for item in findings))
        report = audit_module.markdown(
            scanned, skipped, findings, "https://example.test/issues/34")
        self.assertIn("upstream commit fix(es)", report)
        self.assertIn("CVE-2026-12345", report)
        self.assertIn("not pinned to a stable upstream package version", report)
        self.assertIn("no newer candidate", report)

    def test_major_fix_is_not_misrepresented_as_same_major(self):
        result = {
            "id": "OSV-TEST",
            "summary": "Major fix",
            "affected": [{"ranges": [{"events": [
                {"introduced": "1"}, {"fixed": "2.0.0"}]}]}],
        }
        rendered = audit_module.markdown(
            [{"id": "x", "pin": "1.2.3"}], [], [{
                "id": "x", "pin": "1.2.3", "severity": "high",
                "fixed": ["2.0.0"], "vulnerability": result,
            }], "https://example.test/issues/34")
        self.assertIn("major upgrade", rendered)
        self.assertNotIn("same-major fix", rendered)

    def test_package_fixed_release_is_classified_as_same_major(self):
        rendered = audit_module.markdown(
            [{"id": "x", "pin": "1.2.3", "ecosystem": "npm"}], [], [{
                "id": "x", "pin": "1.2.3", "ecosystem": "npm", "severity": "high",
                "fixed": ["1.2.4"],
                "vulnerability": {"id": "GHSA", "summary": "Patch"},
            }], "https://example.test/issues/34")
        self.assertIn("same-major fix", rendered)

    def test_git_commit_hashes_are_not_reported_as_semver_upgrades(self):
        rendered = audit_module.markdown(
            [{"id": "language.runtime", "pin": "1.2.3", "ecosystem": "GIT"}], [], [{
                "id": "language.runtime", "pin": "1.2.3", "ecosystem": "GIT",
                "severity": "unspecified", "fixed": ["abcd1234"],
                "vulnerability": {"id": "OSV-GIT", "summary": "Commit-based advisory"},
            }], "https://example.test/issues/34")
        self.assertIn("upstream commit fix(es)", rendered)
        self.assertNotIn("major upgrade", rendered)

    def test_incomplete_batch_response_fails_closed(self):
        with self.assertRaisesRegex(RuntimeError, "incomplete batch"):
            audit_module.audit(self.root, request=lambda *_: {"results": []})

    def test_paginated_response_fails_instead_of_hiding_advisories(self):
        def paginated(*_):
            return {"results": [{"vulns": [], "next_page_token": "next"},
                                {"vulns": []}]}
        with self.assertRaisesRegex(RuntimeError, "partial audit"):
            audit_module.audit(self.root, request=paginated)

    def test_latest_compatible_and_latest_stable_git_candidates(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / "update-policy.json").write_text(
            '{"languages.python": "minor"}')
        entry = {
            "id": "languages.python", "pin": "3.14.8", "version": "v3.14.8",
            "package": {"ecosystem": "GIT",
                        "name": "https://github.com/python/cpython.git"},
        }
        candidates = audit_module.upgrade_candidates(
            entry, self.root,
            fetch=lambda _: [{"name": tag} for tag in
                             ("v3.15.0", "v3.14.9", "v3.14.10")])
        self.assertEqual(candidates, [
            {"version": "3.14.10", "query_version": "v3.14.10",
             "labels": ["latest-compatible"]},
            {"version": "3.15.0", "query_version": "v3.15.0",
             "labels": ["latest-stable", "outside compatibility policy"]},
        ])

    def test_candidate_advice_prefers_clean_or_lower_severity(self):
        key = ("npm", "demo", "1.0.0")
        entry = {"id": "demo", "pin": "1.0.0", "version": "1.0.0",
                 "ecosystem": "npm", "package": {"ecosystem": "npm", "name": "demo"}}
        current = {"id": "OLD", "severity": [{"score": "8.0"}]}
        finding = {"id": "demo", "coordinate": key, "vulnerability": current}
        options = [{"version": "1.0.1", "query_version": "1.0.1",
                    "labels": ["latest-compatible"]}]
        clean = audit_module.candidate_advice(
            self.root, [entry], [finding],
            request=lambda *_: {"results": [{}]}, fetch=lambda _: {},
            resolve_candidates=lambda *_: options, vulnerability_cache={})
        self.assertIn("no OSV advisories", clean[key])

        low = {"id": "LOW", "database_specific": {"severity": "LOW"}}
        reduced = audit_module.candidate_advice(
            self.root, [entry], [finding],
            request=lambda *_: {"results": [{"vulns": [{"id": "LOW"}]}]},
            fetch=lambda _: low, resolve_candidates=lambda *_: options,
            vulnerability_cache={})
        self.assertIn("maximum severity high to low", reduced[key])

    def test_candidate_with_same_or_unknown_severity_gets_warning(self):
        key = ("npm", "demo", "1.0.0")
        entry = {"id": "demo", "pin": "1.0.0", "version": "1.0.0",
                 "ecosystem": "npm", "package": {"ecosystem": "npm", "name": "demo"}}
        finding = {"id": "demo", "coordinate": key, "vulnerability": {
            "id": "OLD", "database_specific": {"severity": "unspecified"}}}
        advice = audit_module.candidate_advice(
            self.root, [entry], [finding],
            request=lambda *_: {"results": [{"vulns": [{"id": "NEW"}]}]},
            fetch=lambda _: {"id": "NEW", "database_specific": {"severity": "low"}},
            resolve_candidates=lambda *_: [
                {"version": "1.0.1", "query_version": "1.0.1",
                 "labels": ["latest-compatible"]}],
            vulnerability_cache={})
        self.assertIn("WARNING: no newer candidate", advice[key])


if __name__ == "__main__":
    unittest.main()
