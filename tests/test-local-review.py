#!/usr/bin/env python3
"""User-invoked local reviews never expose raw machine data or change settings."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = (
    Path(sys.argv.pop(1)).resolve()
    if len(sys.argv) > 1
    else Path(__file__).resolve().parents[1]
)


class LocalReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / "private-person-77"
        self.home.mkdir()
        self.state = self.home / ".local/state/dotfiles"
        self.state.mkdir(parents=True)
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "DOTFILES_STATE_DIR": str(self.state),
            "DOTFILES_SOURCE_DIR": str(ROOT),
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        self.secret = (
            "private-person-77 secret.example.invalid 192.0.2.77 token-super-private"
        )
        (self.home / ".zshrc").write_text(
            "# " + self.secret + "\nexport HISTSIZE=34567\n"
        )

    def cli(self, *args):
        return subprocess.run(
            [
                "/usr/bin/python3",
                str(ROOT / "scripts/local-review.py"),
                "--source",
                str(ROOT),
                *map(str, args),
            ],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_offline_check_has_only_codes_and_does_not_change_machine_files(self):
        before = {
            str(path): path.read_bytes()
            for path in self.home.rglob("*")
            if path.is_file()
        }
        result = self.cli("check", "--json")
        self.assertIn(result.returncode, (0, 1), result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual("dotfiles-local-check", report["kind"])
        self.assertTrue(report["checks"])
        self.assertNotIn("private-person", result.stdout + result.stderr)
        self.assertNotIn("secret.example", result.stdout + result.stderr)
        self.assertNotIn("192.0.2.77", result.stdout + result.stderr)
        self.assertNotIn("token-super-private", result.stdout + result.stderr)
        after = {
            str(path): path.read_bytes()
            for path in self.home.rglob("*")
            if path.is_file()
        }
        self.assertEqual(before, after)

    def test_receipts_have_no_raw_paths_or_values_and_compare_offline(self):
        first = self.home / "first.json"
        result = self.cli("receipt", "create", "--output", first)
        self.assertEqual(0, result.returncode, result.stderr)
        report = json.loads(first.read_text())
        self.assertEqual("dotfiles-receipt", report["kind"])
        self.assertEqual(0o600, first.stat().st_mode & 0o777)
        self.assertNotIn(str(self.home), first.read_text())
        self.assertNotIn("private-person", first.read_text())
        self.assertNotIn("PATH", first.read_text())
        same = self.cli("receipt", "compare", first, first)
        self.assertEqual(0, same.returncode, same.stderr)
        self.assertEqual([], json.loads(same.stdout)["changes"])

    def test_capture_only_exports_allowlisted_typed_changes(self):
        patch = self.home / "settings.patch"
        result = self.cli("capture", "zsh", "--output", patch)
        self.assertEqual(0, result.returncode, result.stderr)
        text = patch.read_text()
        self.assertIn("+HISTSIZE=34567", text)
        self.assertIn("b/dot_zshrc.tmpl", text)
        self.assertNotIn("private-person", text + result.stdout + result.stderr)
        self.assertNotIn("secret.example", text)
        self.assertNotIn("192.0.2.77", text)
        self.assertNotIn("token-super-private", text)
        self.assertEqual(0o600, patch.stat().st_mode & 0o777)
        self.assertIn(self.secret, (self.home / ".zshrc").read_text())

    def test_capture_rejects_computed_values_without_echoing_them(self):
        (self.home / ".zshrc").write_text('HISTSIZE="$(echo token-super-private)"\n')
        patch = self.home / "invalid.patch"
        result = self.cli("capture", "zsh", "--output", patch)
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(patch.exists())
        self.assertNotIn("token-super-private", result.stdout + result.stderr)

    def test_receipt_uses_cached_versions_without_executing_tools(self):
        command = self.home / ".local/bin/node"
        command.parent.mkdir(parents=True)
        marker = self.home / "tool-was-executed"
        command.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 99\n")
        command.chmod(0o755)
        self.env["PATH"] = str(command.parent) + ":" + self.env["PATH"]
        info = command.stat()
        snapshot = {
            "schema": 1,
            "entries": {
                "languages.node": {
                    "path": str(command),
                    "version": "26.11.1",
                    "signature": {
                        "resolved": str(command.resolve()),
                        "mtime_ns": info.st_mtime_ns,
                        "size": info.st_size,
                    },
                    "raw_output": self.secret,
                }
            },
        }
        (self.state / "catalog.json").write_text(json.dumps(snapshot))
        (self.state / "installed.tsv").write_text(
            f"node\t26.11.1\tmanaged\t{command}\tlanguages\tprivate-date\n"
        )
        result = self.cli("receipt", "create")
        self.assertEqual(0, result.returncode, result.stderr)
        data = json.loads(result.stdout)
        node = next(item for item in data["tools"] if item["id"] == "languages.node")
        self.assertEqual("26.11.1", node["version"])
        self.assertEqual("recorded-unverified", node["management"])
        self.assertFalse(marker.exists())
        for private in (
            "private-person",
            "private-date",
            "secret.example",
            "raw_output",
        ):
            self.assertNotIn(private, result.stdout + result.stderr)
        changed = json.loads(result.stdout)
        next(item for item in changed["tools"] if item["id"] == "languages.node")[
            "version"
        ] = "27.0.0"
        before = self.home / "before.json"
        after = self.home / "after.json"
        before.write_text(result.stdout)
        after.write_text(json.dumps(changed))
        compared = self.cli("receipt", "compare", before, after)
        self.assertEqual(0, compared.returncode, compared.stderr)
        self.assertIn("27.0.0", compared.stdout)

    def test_untrusted_receipt_errors_never_echo_private_fields(self):
        result = self.cli("receipt", "create")
        self.assertEqual(0, result.returncode, result.stderr)
        data = json.loads(result.stdout)
        data["private"] = self.secret
        path = self.home / "tainted.json"
        path.write_text(json.dumps(data))
        rejected = self.cli("receipt", "compare", path, path)
        self.assertNotEqual(0, rejected.returncode)
        self.assertNotIn("private-person", rejected.stdout + rejected.stderr)

    def test_output_refuses_existing_or_symlinked_destinations(self):
        original = self.home / "keep.json"
        original.write_text(self.secret)
        link = self.home / "link.json"
        link.symlink_to(original)
        for path in (original, link):
            result = self.cli("receipt", "create", "--output", path)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual(self.secret, original.read_text())

        directory = self.home / "real-output"
        directory.mkdir()
        redirected = self.home / "redirected"
        redirected.symlink_to(directory, target_is_directory=True)
        result = self.cli("receipt", "create", "--output", redirected / "report.json")
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((directory / "report.json").exists())

    def test_check_reports_invalid_syntax_without_sourcing_startup_files(self):
        marker = self.home / "startup-was-executed"
        startup = self.home / "startup"
        startup.write_text(f"touch '{marker}'\n")
        self.env["BASH_ENV"] = str(startup)
        self.env["ENV"] = str(startup)
        (self.home / ".bashrc").write_text("if token-super-private; then\n")
        result = self.cli("check", "--json")
        self.assertEqual(1, result.returncode, result.stderr)
        checks = {
            item["id"]: item["status"] for item in json.loads(result.stdout)["checks"]
        }
        self.assertEqual("attention", checks["shell.bash.syntax"])
        self.assertFalse(marker.exists())
        self.assertNotIn("token-super-private", result.stdout + result.stderr)

    def test_receipt_rejects_boolean_schema_without_echoing_private_data(self):
        result = self.cli("receipt", "create")
        self.assertEqual(0, result.returncode, result.stderr)
        data = json.loads(result.stdout)
        data["schema"] = True
        path = self.home / "bad-schema.json"
        path.write_text(json.dumps(data))
        result = self.cli("receipt", "compare", path, path)
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("private-person", result.stdout + result.stderr)

    def test_installed_audit_is_offline_and_never_claims_missing_data_is_clean(self):
        receipt = self.home / "receipt.json"
        self.assertEqual(
            0, self.cli("receipt", "create", "--output", receipt).returncode
        )
        result = self.cli("audit", "--installed", "--receipt", receipt)
        self.assertEqual(0, result.returncode, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual("dotfiles-installed-audit", data["kind"])
        self.assertEqual("offline", data["source"])
        self.assertNotIn("clean", result.stdout)
        self.assertNotIn("private-person", result.stdout + result.stderr)

    def test_installed_audit_uses_exact_observed_version_not_repo_pin(self):
        report = self.cli("receipt", "create")
        data = json.loads(report.stdout)
        node = next(item for item in data["tools"] if item["id"] == "languages.node")
        node.update(
            version="27.0.0", state="observed", management="external-or-unrecorded"
        )
        receipt = self.home / "observed.json"
        receipt.write_text(json.dumps(data))
        cache = self.home / "advisories.json"
        cache.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "kind": "dotfiles-advisories",
                    "as_of": "2026-10-22",
                    "tools": [
                        {
                            "id": "languages.node",
                            "version": "27.0.0",
                            "advisories": [
                                {
                                    "id": "CVE-2026-12345",
                                    "severity": "high",
                                    "fixed": ["27.0.1"],
                                }
                            ],
                        }
                    ],
                }
            )
        )
        result = self.cli(
            "audit", "--installed", "--receipt", receipt, "--advisories", cache
        )
        self.assertEqual(0, result.returncode, result.stderr)
        audited = next(
            item
            for item in json.loads(result.stdout)["tools"]
            if item["id"] == "languages.node"
        )
        self.assertEqual("27.0.0", audited["version"])
        self.assertEqual("advisories", audited["status"])
        self.assertEqual("high", audited["advisories"][0]["severity"])
        node["version"] = "28.0.0"
        receipt.write_text(json.dumps(data))
        result = self.cli(
            "audit", "--installed", "--receipt", receipt, "--advisories", cache
        )
        audited = next(
            item
            for item in json.loads(result.stdout)["tools"]
            if item["id"] == "languages.node"
        )
        self.assertEqual("unknown", audited["status"])

    def test_tmux_and_starship_capture_exclude_other_local_settings(self):
        for target, filename, content, expected in (
            (
                "tmux",
                ".tmux.conf",
                "set -g history-limit 45678\n# " + self.secret + "\n",
                "+set -g history-limit 45678",
            ),
            (
                "starship",
                ".config/starship.toml",
                "# "
                + self.secret
                + '\n[directory]\ntruncation_length = 7\nformat = "private-person-77"\n',
                "+truncation_length = 7",
            ),
        ):
            with self.subTest(target=target):
                local = self.home / filename
                local.parent.mkdir(parents=True, exist_ok=True)
                local.write_text(content)
                output = self.home / (target + ".patch")
                result = self.cli("capture", target, "--output", output)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn(expected, output.read_text())
                self.assertNotIn(
                    "private-person", output.read_text() + result.stdout + result.stderr
                )

    def test_capture_refuses_symlinked_configs_and_never_executes_shell(self):
        local = self.home / ".zshrc"
        (self.home / "original").write_text(local.read_text())
        local.unlink()
        local.symlink_to(self.home / "original")
        result = self.cli("capture", "zsh", "--output", self.home / "linked.patch")
        self.assertNotEqual(0, result.returncode)
        self.assertTrue(local.is_symlink())
        local.unlink()
        marker = self.home / "never-run"
        local.write_text(f"touch '{marker}'\nHISTSIZE=34567\n")
        result = self.cli("capture", "zsh", "--output", self.home / "literal.patch")
        self.assertEqual(0, result.returncode, result.stderr)
        checked = self.cli("check", "--json")
        self.assertIn(checked.returncode, (0, 1), checked.stderr)
        self.assertFalse(marker.exists())

    def test_online_audit_only_sends_public_coordinates_and_strips_vendor_text(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        from dotfiles import installed_audit

        data = json.loads(self.cli("receipt", "create").stdout)
        data["tools"] = [
            {
                "id": "languages.node",
                "version": "27.0.0",
                "state": "observed",
                "management": "external-or-unrecorded",
            }
        ]
        queries = []

        def request(url, payload):
            queries.append(payload)
            return {"results": [{"vulns": [{"id": "CVE-2026-12345"}]}]}

        def fetch(url):
            return {
                "id": "CVE-2026-12345",
                "summary": self.secret,
                "database_specific": {"severity": "HIGH"},
                "affected": [
                    {
                        "ranges": [
                            {"events": [{"fixed": "27.0.1"}, {"fixed": self.secret}]}
                        ]
                    }
                ],
            }

        report, cache = installed_audit.audit(
            ROOT, data, online=True, request=request, fetch=fetch
        )
        self.assertEqual("v27.0.0", queries[0]["queries"][0]["version"])
        self.assertEqual({"package", "version"}, set(queries[0]["queries"][0]))
        serialized = json.dumps([report, cache, queries])
        self.assertNotIn("private-person", serialized)
        self.assertNotIn("secret.example", serialized)
        self.assertEqual(["27.0.1"], cache["tools"][0]["advisories"][0]["fixed"])
        with patch.object(installed_audit, "audit_module") as module:
            module.return_value.coordinate.return_value = {"version": "v27.0.0"}
            installed_audit.audit(
                ROOT, data, request=lambda *_: self.fail("offline request")
            )

    def test_audit_rejects_tainted_cache_and_partial_network_response(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        from dotfiles import installed_audit

        data = json.loads(self.cli("receipt", "create").stdout)
        data["tools"] = [
            {
                "id": "languages.node",
                "version": "27.0.0",
                "state": "observed",
                "management": "external-or-unrecorded",
            }
        ]
        with self.assertRaises(RuntimeError):
            installed_audit.audit(
                ROOT, data, online=True, request=lambda *_: {"results": []}
            )
        receipt = self.home / "audit-receipt.json"
        receipt.write_text(json.dumps(data))
        cache = self.home / "tainted-advisories.json"
        cache.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "kind": "dotfiles-advisories",
                    "as_of": self.secret,
                    "tools": [],
                }
            )
        )
        result = self.cli(
            "audit", "--installed", "--receipt", receipt, "--advisories", cache
        )
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("private-person", result.stdout + result.stderr)

        cache.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "kind": "dotfiles-advisories",
                    "as_of": "2026-10-22",
                    "tools": [
                        {
                            "id": "languages.node",
                            "version": "27.0.0",
                            "advisories": [
                                {
                                    "id": "private-person-77",
                                    "severity": "high",
                                    "fixed": [],
                                }
                            ],
                        }
                    ],
                }
            )
        )
        result = self.cli(
            "audit", "--installed", "--receipt", receipt, "--advisories", cache
        )
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("private-person", result.stdout + result.stderr)

    def test_dot_routes_the_local_review_commands(self):
        for args in (
            ("check-local", "--json"),
            ("receipt", "create"),
            ("capture", "--list"),
            ("audit", "--installed"),
        ):
            with self.subTest(command=args[0]):
                result = subprocess.run(
                    ["bash", str(ROOT / "dot_local/bin/executable_dot"), *args],
                    env=self.env,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                self.assertIn(result.returncode, (0, 1), result.stderr)
                json.loads(result.stdout)
                self.assertNotIn("private-person", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
