#!/usr/bin/env python3
"""Offline regression coverage for the snapshots used between live E2E passes."""

import importlib.util
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
SPEC = importlib.util.spec_from_file_location(
    "convergence", ROOT / "scripts/convergence.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ConvergenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name) / "home"
        self.state = self.home / "state"
        self.state.mkdir(parents=True)
        self.config = self.home / "config"
        self.config.write_text("stable\n")
        self.config.chmod(0o600)
        self.link = self.home / "command"
        self.link.symlink_to("config")
        self.tool = self.home / "tool"
        self.tool.mkdir()
        (self.tool / "payload").write_text("binary\n")
        self.ledger = self.state / "installed.tsv"
        self.row = f"tool\t1.0.0\ttest\t{self.tool}\tcore\t"
        self.ledger.write_text(self.row + "2026-01-01T00:00:00Z\n")

    def capture(self, diff=""):
        return MODULE.snapshot(self.home, self.state, [self.config, self.link], diff)

    def test_timestamp_only_ledger_changes_are_ignored(self):
        before = self.capture()
        self.ledger.write_text(self.row + "2026-01-02T00:00:00Z\n")
        self.assertEqual([], MODULE.differences(before, self.capture()))

    def test_file_hash_and_modes_are_compared(self):
        before = self.capture()
        self.config.write_text("changed\n")
        self.assertTrue(MODULE.differences(before, self.capture()))
        self.config.write_text("stable\n")
        self.config.chmod(0o644)
        self.assertTrue(MODULE.differences(before, self.capture()))

    def test_symlink_target_is_compared_without_following_it(self):
        before = self.capture()
        self.link.unlink()
        self.link.symlink_to("missing")
        changes = MODULE.differences(before, self.capture())
        self.assertTrue(any(str(self.link) in change for change in changes))

    def test_owned_tree_addition_and_deletion_are_detected(self):
        before = self.capture()
        (self.tool / "extra").write_text("unexpected\n")
        self.assertTrue(MODULE.differences(before, self.capture()))
        (self.tool / "extra").unlink()
        (self.tool / "payload").unlink()
        self.assertTrue(MODULE.differences(before, self.capture()))

    def test_identical_executable_replacement_is_detected(self):
        payload = self.tool / "payload"
        payload.chmod(0o755)
        before = self.capture()
        replacement = self.tool / "replacement"
        replacement.write_bytes(payload.read_bytes())
        replacement.chmod(0o755)
        replacement.replace(payload)
        self.assertTrue(MODULE.differences(before, self.capture()))

    def test_ledger_semantics_and_duplicates_are_not_ignored(self):
        before = self.capture()
        self.ledger.write_text(self.row.replace("1.0.0", "2.0.0") + "today\n")
        self.assertIn(
            "ledger changed between installation passes",
            MODULE.differences(before, self.capture()),
        )
        self.ledger.write_text((self.row + "today\n") * 2)
        self.assertIn(
            "ledger changed between installation passes",
            MODULE.differences(before, self.capture()),
        )

    def test_new_diff_and_backup_are_detected(self):
        before = self.capture()
        self.assertTrue(MODULE.differences(before, self.capture("new config diff")))
        backup = self.state / "binary-backups/replacement"
        backup.mkdir(parents=True)
        (backup / "tool").write_text("old binary\n")
        self.assertTrue(
            any(
                "replacements:" in change
                for change in MODULE.differences(before, self.capture())
            )
        )

    def test_history_and_overlay_preservation(self):
        overlay = self.home / ".config/dotfiles/local.zsh"
        overlay.parent.mkdir(parents=True)
        overlay.write_text("local\n")
        history = self.home / ".zsh_history"
        history.write_text("history\n")
        before = self.capture()
        overlay.write_text("clobbered\n")
        history.chmod(0o777)
        changes = MODULE.differences(before, self.capture())
        self.assertTrue(any(str(overlay) in change for change in changes))
        self.assertTrue(any(str(history) in change for change in changes))

    def test_generated_agent_state_and_runtime_payloads_are_compared(self):
        for relative in (
            ".gemini/antigravity-cli/settings.json",
            ".omp/agent/optimizer.json",
            ".agents/skills/graphify/SKILL.md",
            ".rustup/toolchains/fixture/bin/rustc",
            ".local/share/uv/python/fixture/bin/python3",
        ):
            with self.subTest(relative=relative):
                path = self.home / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("original\n")
                before = self.capture()
                path.write_text("modified\n")
                self.assertTrue(
                    any(
                        str(path) in change
                        for change in MODULE.differences(before, self.capture())
                    )
                )

    def test_malformed_ledger_is_rejected(self):
        self.ledger.write_text("broken\trow\n")
        with self.assertRaises(ValueError):
            self.capture()

    def test_managed_path_must_be_in_test_home(self):
        with self.assertRaises(ValueError):
            MODULE.snapshot(self.home, self.state, [Path("/etc/passwd")], "")

    @unittest.skipUnless(
        shutil.which("chezmoi"), "chezmoi not installed in this test container"
    )
    def test_real_chezmoi_snapshot_cli(self):
        source = self.home.parent / "source"
        source.mkdir()
        (source / "dot_probe").write_text("managed CLI fixture\n")
        env = {**os.environ, "HOME": str(self.home)}
        subprocess.run(
            ["chezmoi", f"--source={source}", "--exclude=scripts", "apply"],
            env=env,
            check=True,
            capture_output=True,
        )
        outputs = [self.home.parent / f"pass-{number}.json" for number in (1, 2)]
        for output in outputs:
            subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/convergence.py"),
                    "snapshot",
                    "--home",
                    str(self.home),
                    "--state",
                    str(self.state),
                    "--source",
                    str(source),
                    "--output",
                    str(output),
                ],
                env=env,
                check=True,
                capture_output=True,
            )
            self.assertEqual(0o600, output.stat().st_mode & 0o777)
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/convergence.py"),
                "compare",
                *map(str, outputs),
            ],
            env=env,
            check=True,
            capture_output=True,
        )
        (self.home / ".probe").write_text("locally changed\n")
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/convergence.py"),
                "snapshot",
                "--home",
                str(self.home),
                "--state",
                str(self.state),
                "--source",
                str(source),
                "--output",
                str(outputs[1]),
            ],
            env=env,
            check=True,
            capture_output=True,
        )
        changed = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/convergence.py"),
                "compare",
                *map(str, outputs),
            ],
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(0, changed.returncode)
        self.assertIn("config_diff changed", changed.stderr)


if __name__ == "__main__":
    unittest.main()
