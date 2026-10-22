#!/usr/bin/env python3
"""Unit tests for the mocked, read-only pinned-version OSV audit."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

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

    def test_repository_git_coordinates_follow_metadata_tag_templates(self):
        packages = audit_module.load_versions(ROOT / "packages.yaml")
        metadata = yaml.safe_load((ROOT / "packages.meta.yaml").read_text())
        for section, tools in metadata.items():
            for name, meta in tools.items():
                if meta.get("source") != "github" or not meta.get("tag_template"):
                    continue
                ident = f"{section}.{name}"
                pin = packages[section][name]
                if not audit_module.stable_version(pin):
                    continue
                with self.subTest(ident=ident):
                    coord = audit_module.coordinate(ident, pin, meta)
                    self.assertIsNotNone(coord)
                    self.assertEqual(coord["version"], meta["tag_template"].format(version=pin))
                    self.assertEqual(coord["package"]["name"], f"https://github.com/{meta['repo']}.git")

    def test_explicit_metadata_overrides_special_git_tag_fallback(self):
        coord = audit_module.coordinate("core.ast_grep", "0.50.0", {
            "source": "github", "repo": "ast-grep/ast-grep", "tag_template": "ast-{version}"})
        self.assertEqual(coord["version"], "ast-0.50.0")

    def test_git_templates_without_one_version_placeholder_fail_closed(self):
        for template in ("latest", "v{version}-{version}", None):
            with self.subTest(template=template), self.assertRaises(ValueError):
                audit_module.coordinate("core.demo", "1.0.0", {
                    "source": "github", "repo": "demo/tool", "tag_template": template})

    def test_metadata_tags_are_used_in_both_current_and_candidate_osv_queries(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / "update-policy.json").write_text('{}')
        vuln = {"id": "STILL-AFFECTED", "database_specific": {"severity": "HIGH"}}
        for template in ("{version}", "release-{version}-stable"):
            with self.subTest(template=template):
                (self.root / "packages.yaml").write_text(yaml.safe_dump({"core": {"demo": "1.0.0"}}))
                (self.root / "packages.meta.yaml").write_text(yaml.safe_dump({"core": {"demo": {
                    "source": "github", "repo": "demo/tool", "tag_template": template,
                }}}))
                queries = []

                def request(_, payload):
                    queries.extend(payload["queries"])
                    return {"results": [{"vulns": [{"id": vuln["id"]}]}]}

                def fetch(url):
                    if url.startswith(audit_module.VULN):
                        return vuln
                    return [{"name": template.format(version="1.0.1")}]

                _, _, findings = audit_module.audit(self.root, request=request, fetch=fetch)
                self.assertEqual([query["version"] for query in queries], [
                    template.format(version="1.0.0"), template.format(version="1.0.1")])
                self.assertEqual(len(findings), 1)
                self.assertIn("WARNING:", findings[0]["recommendation"])

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

    def test_cvss_vectors_and_package_severity_are_normalized(self):
        vectors = [
            ("CVSS_V3", "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H", "critical"),
            ("CVSS_V3", "CVSS:3.0/AV:L/AC:H/PR:H/UI:R/S:U/C:L/I:N/A:N", "low"),
            ("CVSS_V4", "CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:H/SI:H/SA:N", "critical"),
            ("CVSS_V2", "AV:N/AC:L/Au:N/C:P/I:P/A:P", "high"),
            ("CVSS_V2", "AC:L/AV:N/Au:N/C:P/I:P/A:P", "high"),
        ]
        for kind, vector, expected in vectors:
            with self.subTest(kind=kind, vector=vector):
                self.assertEqual(audit_module.severity({
                    "severity": [{"type": kind, "score": vector}]}), expected)
        self.assertEqual(audit_module.severity({"affected": [{
            "severity": [{"type": "CVSS_V3", "score": vectors[0][1]}]}]}), "critical")
        self.assertEqual(audit_module.severity({"database_specific": {"severity": "MEDIUM"}}), "moderate")
        self.assertEqual(audit_module.severity({"severity": [{"score": "4.0"}],
                                               "affected": [{"database_specific": {"severity": "HIGH"}}]}), "high")
        for score in ("CVSS:3.1/invalid", "CVSS:4.0/invalid", "CVSS:2.0/invalid", "11", "-1", "NaN"):
            with self.subTest(score=score):
                self.assertEqual(audit_module.severity({"severity": [{"score": score}]}), "unspecified")

    def test_optional_cvss_dependency_never_turns_unknown_vectors_into_clean(self):
        vector = {"severity": [{"type": "CVSS_V3",
                               "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}]}
        with patch.multiple(audit_module, CVSS2=None, CVSS3=None, CVSS4=None):
            self.assertEqual("unspecified", audit_module.severity(vector))
            vector["database_specific"] = {"severity": "HIGH"}
            self.assertEqual("high", audit_module.severity(vector))
            self.assertEqual("critical", audit_module.severity({"severity": [{"score": "9.8"}]}))

    def test_tagged_git_candidate_still_vulnerable_is_not_clean(self):
        key = ("GIT", "https://github.com/demo/tool.git", "v1.0.0")
        entry = {"id": "demo", "pin": "1.0.0", "version": key[2],
                 "package": {"ecosystem": key[0], "name": key[1]}}
        vuln = {"id": "OLD", "database_specific": {"severity": "HIGH"}}
        requests = []

        def request(_, payload):
            requests.extend(payload["queries"])
            return {"results": [{"vulns": [{"id": "OLD"}]}]}

        advice = audit_module.candidate_advice(
            self.root, [entry], [{"coordinate": key, "vulnerability": vuln}],
            request=request, fetch=lambda _: vuln,
            resolve_candidates=lambda *_: [{"version": "1.0.1", "query_version": "v1.0.1",
                                           "labels": ["latest-compatible"]}],
            vulnerability_cache={"OLD": vuln})
        self.assertEqual(requests[0]["version"], "v1.0.1")
        self.assertIn("WARNING:", advice[key])
        self.assertNotIn("no OSV advisories", advice[key])

    def test_missing_candidate_results_fail_closed(self):
        key = ("npm", "demo", "1.0.0")
        entry = {"id": "demo", "package": {"ecosystem": "npm", "name": "demo"},
                 "version": "1.0.0", "pin": "1.0.0"}
        for response in ({}, {"results": []}, {"results": [None]}):
            with self.subTest(response=response), self.assertRaises(RuntimeError):
                audit_module.candidate_advice(
                    self.root, [entry], [{"coordinate": key, "vulnerability": {"id": "OLD"}}],
                    request=lambda *_: response, fetch=lambda _: {},
                    resolve_candidates=lambda *_: [{"version": "1.0.1", "query_version": "1.0.1",
                                                   "labels": ["latest-compatible"]}],
                    vulnerability_cache={})

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

    def test_registry_candidates_use_shared_installable_release_rules(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / "update-policy.json").write_text('{}')
        (self.root / "packages.yaml").write_text(yaml.safe_dump({"languages": {"node": "26.11.1"}}))
        npm = {"id": "demo", "pin": "1.0.0", "version": "1.0.0",
               "package": {"ecosystem": "npm", "name": "demo"}}
        data = {"dist-tags": {"latest": "2.0.0"}, "versions": {
            "1.1.0": {"engines": {"node": ">=26"}},
            "2.0.0": {"engines": {"node": ">=27"}},
            "3.0.0": {"engines": {"node": ">=26"}},
        }}
        candidates = audit_module.upgrade_candidates(npm, self.root, fetch=lambda _: data)
        self.assertEqual(candidates, [{"version": "1.1.0", "query_version": "1.1.0",
                                       "labels": ["latest-compatible", "latest-stable"]}])
        pypi = {**npm, "package": {"ecosystem": "PyPI", "name": "demo"}}
        candidates = audit_module.upgrade_candidates(pypi, self.root, fetch=lambda _: {"releases": {
            "1.1.0": [{"yanked": False}], "2.0.0": [{"yanked": True}], "3.0.0": [],
        }})
        self.assertEqual([item["version"] for item in candidates], ["1.1.0"])

    def test_candidate_pagination_or_malformed_advisories_fail_closed(self):
        key = ("npm", "demo", "1.0.0")
        entry = {"id": "demo", "version": key[2], "pin": key[2],
                 "package": {"ecosystem": key[0], "name": key[1]}}
        for result in ({"next_page_token": "more"}, {"vulns": None}, {"vulns": [{}]},
                       {"error": "query failed"}):
            with self.subTest(result=result), self.assertRaises(RuntimeError):
                audit_module.candidate_advice(
                    self.root, [entry], [{"coordinate": key, "vulnerability": {"id": "OLD"}}],
                    request=lambda *_: {"results": [result]}, fetch=lambda _: {},
                    resolve_candidates=lambda *_: [{"version": "1.0.1", "query_version": "1.0.1",
                                                   "labels": ["latest-compatible"]}],
                    vulnerability_cache={})

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
