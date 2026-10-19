#!/usr/bin/env bash
# Catalog coverage, offline queries, bounded probes, picker, and dot routing.
set -euo pipefail
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 - "$DOTFILES_DIR" <<'PYTEST'
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("catalog", root / "scripts/catalog.py")
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name) / "state"
        self.env = {**os.environ, "DOTFILES_STATE_DIR": str(self.state), "DOTFILES_SOURCE_DIR": str(root)}

    def query(self, *args):
        return subprocess.run([sys.executable, str(root / "scripts/catalog.py"), *args],
                              env=self.env, text=True, capture_output=True, check=True)

    def test_coverage_and_tags(self):
        entries = catalog.catalog()
        ids = {entry["id"] for entry in entries}
        manifest = catalog.yaml.safe_load((root / "packages.yaml").read_text())
        for section, tools in manifest.items():
            self.assertTrue({f"{section}.{tool}" for tool in tools} <= ids)
        self.assertEqual(len(ids), len(entries))
        for entry in entries:
            self.assertGreater(len(entry["description"].split()), 2, entry["id"])
            self.assertTrue(not entry["commands"] or set(entry["commands"]) <= set(entry.get("binary_descriptions", {})), entry["id"])
            self.assertTrue(not entry["commands"] or entry.get("examples"), entry["id"])
            for example in entry.get("examples", []):
                self.assertIsInstance(example, dict, entry["id"])
                self.assertTrue(example.get("command"), entry["id"])
                self.assertGreater(len(example.get("description", "").split()), 2, entry["id"])
        usql = next(entry for entry in entries if entry["id"] == "database.usql")
        self.assertTrue({"db", "database", "rdb", "rdbms", "postgresql"} <= set(usql["tags"]))
        self.assertEqual(usql["upstream"], "https://github.com/xo/usql")
        atuin = next(entry for entry in entries if entry["id"] == "history.atuin")
        self.assertIn("shell history", atuin["description"])
        self.assertEqual(atuin["binary_descriptions"]["atuin"], "Shell history database, sync client, and search UI")

    def test_offline_search_filters_and_details(self):
        result = json.loads(self.query("postgresql", "--available", "--json").stdout)
        self.assertIn("database.usql", [entry["id"] for entry in result])
        result = json.loads(self.query("--category", "languages", "--available", "--json").stdout)
        self.assertTrue(result)
        self.assertTrue(all(entry["category"] == "languages" for entry in result))
        result = json.loads(self.query("--tag", "vpn", "--available", "--json").stdout)
        self.assertIn("network.tailscale", [entry["id"] for entry in result])
        result = json.loads(self.query("prior", "entries", "--available", "--json").stdout)
        self.assertIn("history.atuin", [entry["id"] for entry in result])
        self.assertFalse(self.state.exists())
        self.assertIn("Example (not executed)", self.query("show", "database.usql").stdout)
        atuin_details = self.query("show", "history.atuin").stdout
        self.assertIn("atuin: Shell history", atuin_details)
        self.assertIn("Find prior history entries", atuin_details)

    def test_queries_never_probe_and_stale_path(self):
        self.state.mkdir()
        (self.state / "catalog.json").write_text(json.dumps({"schema": 1, "entries": {"core.fzf": {"path": "/old/fzf", "version": "9.9"}}}))
        with patch.dict(os.environ, self.env), patch.object(catalog, "locate", return_value=("fzf", "/new/fzf")), patch.object(catalog.subprocess, "run", side_effect=AssertionError("query executed binary")):
            entries = catalog.view(catalog.catalog())
            self.assertIsNone(next(entry for entry in entries if entry["id"] == "core.fzf")["installed_version"])

    def test_probe_arguments_and_timeout(self):
        entry = {"id": "cloud.kubectl", "commands": ["kubectl"]}
        with patch.object(catalog, "locate", return_value=("kubectl", "/mock/kubectl")), patch.object(catalog.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, '{"clientVersion":{"gitVersion":"v1.37.1"}}', "")) as run:
            self.assertEqual(catalog.probe(entry)[1]["version"], "1.37.1")
            self.assertEqual(run.call_args.args[0], ["/mock/kubectl", "version", "--client", "-o", "json"])
            self.assertEqual(run.call_args.kwargs["timeout"], 3)
        with patch.object(catalog, "locate", return_value=("kubectl", "/mock/kubectl")), patch.object(catalog.subprocess, "run", side_effect=subprocess.TimeoutExpired("kubectl", 3)):
            self.assertEqual(catalog.probe(entry)[1]["probe"], "timeout")
        with patch.object(catalog, "locate", return_value=("kubectl", "/mock/kubectl")), patch.object(catalog.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "failure")):
            self.assertEqual(catalog.probe(entry)[1]["probe"], "failed")
        with patch.object(catalog, "locate", return_value=("wg", "/mock/wg")), patch.object(catalog.subprocess, "run", side_effect=AssertionError("unsafe probe")):
            self.assertEqual(catalog.probe(entry)[1]["probe"], "not-supported")

    def test_json_probe_uses_cli_field_not_component_version(self):
        fixtures = [
            ("gcloud", {"bundled-python3-unix": "3.14.0", "Google Cloud SDK": "600.0.0"}, "600.0.0"),
            ("az", {"extensions": {"other": "99.0.0"}, "azure-cli": "2.91.0"}, "2.91.0"),
            ("kubectl", {"kustomizeVersion": "v5.9.0", "clientVersion": {"gitVersion": "v1.37.1"}}, "1.37.1"),
            ("terraform", {"provider_selections": {"example": "99.0.0"}, "terraform_version": "1.16.5"}, "1.16.5"),
        ]
        for command, data, expected in fixtures:
            entry = {"id": command, "commands": [command]}
            with patch.object(catalog, "locate", return_value=(command, "/mock/" + command)), patch.object(catalog.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(data), "")):
                self.assertEqual(catalog.probe(entry)[1]["version"], expected)
        with patch.object(catalog, "locate", return_value=("az", "/mock/az")), patch.object(catalog.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "not json", "")):
            self.assertIsNone(catalog.probe({"id": "az", "commands": ["az"]})[1]["version"])

    def test_fzf_external_path_and_nonstandard_version_probes(self):
        home = Path(self.temp.name) / "home"
        binary = home / ".fzf/bin/fzf"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/bin/sh\necho 0.74.5\n")
        binary.chmod(0o755)
        with patch.object(catalog.shutil, "which", return_value=None), patch.object(catalog.Path, "home", return_value=home):
            self.assertEqual(catalog.locate({"commands": ["fzf"]}), ("fzf", str(binary)))
        self.assertEqual(catalog.PROBES["k9s"], ["version", "--short"])
        self.assertEqual(catalog.PROBES["kubecolor"], ["--kubecolor-version"])

    def test_refresh_private_snapshot(self):
        with patch.dict(os.environ, self.env), patch.object(catalog, "probe", return_value=("fixture.tool", {"version": "1.2.3", "path": "/mock/tool"})):
            catalog.refresh([{"id": "fixture.tool"}])
        path = self.state / "catalog.json"
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        self.assertEqual(json.loads(path.read_text())["schema"], 1)

    def test_cached_version_invalidated_by_binary_change(self):
        binary = Path(self.temp.name) / "node"
        binary.write_text("#!/bin/sh\nprintf 'v26.11.1\\n'\n")
        binary.chmod(0o700)
        entry = {"id": "languages.node", "commands": ["node"]}
        with patch.dict(os.environ, self.env), patch.object(catalog, "locate", return_value=("node", str(binary))):
            catalog.refresh([entry])
            observed = catalog.view(catalog.catalog())
            self.assertEqual(next(item for item in observed if item["id"] == "languages.node")["installed_version"], "26.11.1")
            binary.write_text("#!/bin/sh\nprintf 'v26.12.0 changed\\n'\n")
            observed = catalog.view(catalog.catalog())
            self.assertIsNone(next(item for item in observed if item["id"] == "languages.node")["installed_version"])

    def test_picker_preview_and_cancel(self):
        with patch.object(sys, "argv", ["catalog", "--available", "--pick", "postgresql"]), patch.object(catalog.shutil, "which", return_value="/mock/fzf"), patch.object(catalog.subprocess, "run", return_value=subprocess.CompletedProcess([], 130, "")) as run:
            self.assertEqual(catalog.main(), 0)
            command = run.call_args.args[0]
            self.assertIn("show {1}", command[command.index("--preview") + 1])
            self.assertIn("database.usql", run.call_args.kwargs["input"])
        with patch.object(sys, "argv", ["catalog", "--available", "--pick", "postgresql"]), patch.object(catalog.shutil, "which", return_value="/mock/fzf"), patch.object(catalog.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "database.usql\tdescription\n")), patch.object(catalog, "details") as details:
            self.assertEqual(catalog.main(), 0)
            self.assertEqual(details.call_args.args[0]["id"], "database.usql")

    def test_installed_default_and_empty_picker(self):
        with patch.object(sys, "argv", ["catalog", "--json"]), patch.object(catalog, "locate", return_value=(None, None)), patch("builtins.print") as output:
            self.assertEqual(catalog.main(), 0)
            self.assertEqual(output.call_args.args[0], "[]")
        with patch.object(sys, "argv", ["catalog", "--available", "--pick", "does-not-exist"]), patch.object(catalog.shutil, "which", return_value="/mock/fzf"), patch.object(catalog.subprocess, "run", side_effect=AssertionError("empty picker launched")):
            self.assertEqual(catalog.main(), 0)

    def test_dot_routing(self):
        for subcommand in ("tools", "catalog"):
            result = subprocess.run(["bash", str(root / "dot_local/bin/executable_dot"), subcommand, "--available", "--json"], env=self.env, capture_output=True, text=True, check=True)
            self.assertIn("ai_tools.omp", [entry["id"] for entry in json.loads(result.stdout)])

    def test_invalid_snapshot_has_recovery_message(self):
        self.state.mkdir()
        (self.state / "catalog.json").write_text('[]')
        result = subprocess.run([sys.executable, str(root / "scripts/catalog.py"), "--json"], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("dot tools refresh", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_real_fzf_filter(self):
        if not catalog.shutil.which("fzf"):
            self.skipTest("fzf is unavailable")
        self.env["FZF_DEFAULT_OPTS"] = "--filter=database.usql"
        result = self.query("--available", "--pick", "postgresql")
        self.assertIn("database.usql", result.stdout)
        self.assertIn("Tags:", result.stdout)

    def test_ssh_local_precedence_without_connecting(self):
        ssh = "/usr/bin/ssh"
        if not Path(ssh).exists():
            self.skipTest("OpenSSH client is unavailable")
        directory = Path(self.temp.name)
        overlay = directory / "config.local"
        overlay.write_text("Host rpi4\n    User local-user\n    Port 2222\n")
        config = directory / "config"
        template = (root / "private_dot_ssh/private_config.tmpl").read_text()
        self.assertIn(".ssh/config.local", (root / ".chezmoiignore").read_text())
        config.write_text(template.replace("Include ~/.ssh/config.local", f"Include {overlay}"))
        result = subprocess.run([ssh, "-G", "-F", str(config), "rpi4"], capture_output=True, text=True, check=True)
        self.assertIn("user local-user\n", result.stdout)
        self.assertIn("port 2222\n", result.stdout)
        self.assertIn("cloudflare-ssh proxy", result.stdout)


unittest.main(argv=[sys.argv[0]], verbosity=2)
PYTEST
