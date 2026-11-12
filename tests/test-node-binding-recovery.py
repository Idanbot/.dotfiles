#!/usr/bin/env python3
"""Retry partial managed Node publication using synthetic offline runtimes."""

from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / ".chezmoiscripts/run_once_04-install-languages.sh.tmpl").read_text()
BLOCK = SOURCE[SOURCE.index("NODE_VERSION="):SOURCE.index("TYPESCRIPT_VERSION=")]
PINS = yaml.safe_load((ROOT / "packages.yaml").read_text())["languages"]


class NodeRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="node-recovery-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / ".local/bin"
        self.bin.mkdir(parents=True)
        self.runtime = self.home / ".local/share/dotfiles/tools/node" / PINS["node"]
        self.env = {
            "HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin",
            "DOTFILES_SOURCE_DIR": str(ROOT), "DOTFILES_STATE_DIR": str(self.home / "state"),
            "RUNTIME": str(self.runtime), "VERSION": PINS["node"], "NO_COLOR": "1",
        }
        self.command(self.runtime / "bin/node", PINS["node"])
        for binary in ("npm", "npx"):
            self.command(self.runtime / "bin" / binary, PINS["npm"])
        self.shell('record_install node "$VERSION" node-dist "$RUNTIME"; '
                   'managed_link "$RUNTIME/bin/node" "$HOME/.local/bin/node" node "$VERSION"')

    def command(self, path, version):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/bin/sh\necho {version}\n")
        path.chmod(0o755)

    def shell(self, code, success=True):
        result = subprocess.run(
            ["bash", "-c", 'set -euo pipefail; source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; ' + code],
            env=self.env, capture_output=True, text=True, timeout=20,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def run_block(self, success=True):
        return self.shell('ARCH=amd64; download_verified() { exit 99; }; ' + BLOCK, success)

    def test_retry_repairs_missing_bindings_and_then_is_a_noop(self):
        self.run_block()
        for binary in ("npm", "npx"):
            self.assertEqual((self.bin / binary).resolve(), self.runtime / "bin" / binary)
        ledger = self.home / "state/installed.tsv"
        before = ledger.read_bytes()
        self.shell('ARCH=amd64; target_is_owned() { exit 99; }; ' + BLOCK)
        self.assertEqual(ledger.read_bytes(), before)

    def test_modified_runtime_or_node_link_does_not_authorize_repair(self):
        for change in ("payload", "link"):
            with self.subTest(change=change):
                if change == "payload":
                    marker = self.runtime / "local-change"
                    marker.write_text("preserve")
                else:
                    marker.unlink()
                    (self.bin / "node").unlink()
                    (self.bin / "node").symlink_to(self.runtime / "bin/../bin/node")
                result = self.run_block(success=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.bin / "npm").exists())

    def test_unowned_or_dangling_npm_binding_is_preserved(self):
        for dangling in (False, True):
            with self.subTest(dangling=dangling):
                target = self.bin / "npm"
                if dangling:
                    target.unlink()
                    target.symlink_to(self.home / "unavailable")
                else:
                    self.command(target, PINS["npm"])
                before = target.lstat()
                self.run_block(success=not dangling)
                self.assertEqual(target.lstat().st_ino, before.st_ino)

    def test_newer_owned_runtime_is_not_repaired_to_the_repository_pin(self):
        self.command(self.runtime / "bin/node", "99.0.0")
        self.shell('record_install node "$VERSION" node-dist "$RUNTIME"')
        self.run_block(success=False)
        self.assertFalse((self.bin / "npm").exists())


if __name__ == "__main__":
    if not Path("/.dockerenv").exists():
        raise SystemExit("Run these fixtures inside Docker")
    unittest.main()
