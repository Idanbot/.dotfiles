#!/usr/bin/env python3
"""Real Chezmoi decisions after source, content, permissions, or symlink drift."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = (
    Path(sys.argv.pop(1)).resolve()
    if len(sys.argv) > 1
    else Path(__file__).resolve().parents[1]
)


@unittest.skipUnless(shutil.which("chezmoi"), "chezmoi required")
class DriftTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.source = self.root / "source"
        self.home.mkdir()
        self.source.mkdir()
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "CHEZMOI_SOURCE": str(self.source),
            "CONFLICT_AUTO_APPROVE": "false",
            "NO_COLOR": "1",
        }
        self.managed = self.source / "dot_zshrc"
        self.managed.write_text("export MANAGED_VALUE=old\n")
        self.chezmoi("apply", "--force")
        self.target = self.home / ".zshrc"
        self.target.write_text("export MANAGED_VALUE=local\nexport KEEP_LOCAL=yes\n")
        self.target.chmod(0o640)
        self.managed.write_text("export MANAGED_VALUE=new\n")
        self.preserved = {}
        for relative in (
            ".zsh_history",
            ".bash_history",
            ".ssh/config.local",
            ".config/dotfiles/local.zsh",
        ):
            path = self.home / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("local sentinel\n")
            path.chmod(0o600)
            self.preserved[path] = (path.read_bytes(), path.stat().st_mode)

    def chezmoi(self, *arguments):
        return subprocess.run(
            [
                "chezmoi",
                f"--source={self.source}",
                "--exclude=scripts,externals",
                *arguments,
            ],
            env=self.env,
            capture_output=True,
            text=True,
            check=True,
        )

    def decide(self, answer):
        sources = {
            path: path.read_bytes() for path in self.source.rglob("*") if path.is_file()
        }
        script = """set -euo pipefail
source "$1/scripts/conflicts.sh"
log_info() { :; }; log_success() { :; }; log_warn() { :; }; log_skip() { :; }
log_error() { printf '%s\\n' "$*" >&2; }
read_user() { local prompt="$1" destination="$2" selected_choice; IFS= read -r selected_choice || return 1; printf -v "$destination" '%s' "$selected_choice"; }
CHEZMOI_STATUS_OUTPUT="$(chezmoi status --source="$CHEZMOI_SOURCE" --exclude=scripts,externals)"
export CHEZMOI_STATUS_OUTPUT
dotfiles_apply_selected_conflicts
"""
        result = subprocess.run(
            ["bash", "-c", script, "_", str(ROOT)],
            env=self.env,
            input=answer,
            capture_output=True,
            text=True,
            cwd=self.source,
        )
        for path, expected in self.preserved.items():
            self.assertEqual(
                expected, (path.read_bytes(), path.stat().st_mode), str(path)
            )
        for path, content in sources.items():
            self.assertEqual(content, path.read_bytes())
        self.assertFalse(list(self.home.rglob(".dotfiles-merge.*")))
        return result

    def test_skip_and_quit_preserve_local_config_exactly(self):
        before = (self.target.read_bytes(), self.target.stat().st_mode)
        self.assertEqual(0, self.decide("s\n").returncode)
        self.assertEqual(before, (self.target.read_bytes(), self.target.stat().st_mode))
        for choice in ("q\n", ""):
            self.assertEqual(130, self.decide(choice).returncode)
            self.assertEqual(
                before, (self.target.read_bytes(), self.target.stat().st_mode)
            )

    def test_explicit_replace_repairs_drift_and_converges(self):
        self.assertEqual(0, self.decide("r\n").returncode)
        self.assertEqual(self.managed.read_text(), self.target.read_text())
        self.assertFalse(self.chezmoi("status").stdout.strip())
        before = (self.target.read_bytes(), self.target.stat().st_mode)
        self.assertEqual(0, self.decide("").returncode)
        self.assertEqual(before, (self.target.read_bytes(), self.target.stat().st_mode))

    def test_append_merge_is_repeatable_and_preserves_local_lines(self):
        merged = self.decide("m\n")
        self.assertEqual(0, merged.returncode, merged.stderr)
        before = self.target.read_bytes()
        self.assertIn(b"export KEEP_LOCAL=yes", before)
        self.assertIn(b"export MANAGED_VALUE=new", before)
        self.assertEqual(0o640, self.target.stat().st_mode & 0o777)
        repeated = self.decide("m\n")
        self.assertEqual(0, repeated.returncode, repeated.stderr)
        self.assertEqual(before, self.target.read_bytes())

    def test_source_updates_refresh_merge_without_duplicating_local_content(self):
        self.assertEqual(0, self.decide("m\n").returncode)
        with self.target.open("a") as stream:
            stream.write("export ADDED_LATER=yes\n")
        self.managed.write_text("export MANAGED_VALUE=newest\n")
        refreshed = self.decide("m\n")
        self.assertEqual(0, refreshed.returncode, refreshed.stderr)
        content = self.target.read_text()
        self.assertTrue(content.startswith(self.managed.read_text()))
        self.assertEqual(1, content.count("export KEEP_LOCAL=yes"))
        self.assertEqual(1, content.count("export ADDED_LATER=yes"))
        self.assertEqual(1, content.count("# >>> dotfiles merged local content"))
        self.assertNotIn("export MANAGED_VALUE=new\n", content)
        self.assertEqual(0o640, self.target.stat().st_mode & 0o777)

    def test_invalid_merge_preserves_destination_and_cleans_temporary_files(self):
        self.managed.write_text("if then\n")
        before = (self.target.read_bytes(), self.target.stat().st_mode)
        rejected = self.decide("m\n")
        self.assertNotEqual(0, rejected.returncode)
        self.assertEqual(before, (self.target.read_bytes(), self.target.stat().st_mode))

    def test_retargeted_symlink_is_not_followed_or_replaced_on_skip(self):
        foreign = self.root / "foreign.zsh"
        foreign.write_text("external configuration\n")
        self.target.unlink()
        self.target.symlink_to(foreign)
        self.assertEqual(0, self.decide("s\n").returncode)
        self.assertTrue(self.target.is_symlink())
        self.assertEqual(foreign, self.target.resolve())
        self.assertEqual("external configuration\n", foreign.read_text())

    def test_private_mode_drift_requires_a_choice(self):
        self.managed.unlink()
        self.target.unlink()
        source = self.source / "private_dot_ssh/private_config"
        source.parent.mkdir()
        source.write_text("Host fixture\n  HostName fixture.invalid\n")
        self.chezmoi("apply", "--force")
        target = self.home / ".ssh/config"
        target.chmod(0o644)
        self.assertEqual(0, self.decide("s\n").returncode)
        self.assertEqual(0o644, target.stat().st_mode & 0o777)
        self.assertEqual(0, self.decide("r\n").returncode)
        self.assertEqual(0o600, target.stat().st_mode & 0o777)


if __name__ == "__main__":
    unittest.main()
