#!/usr/bin/env python3
"""Disposable fixtures for backup publication and cross-process locking."""

import fcntl
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BackupLockTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="backup home ")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.state = self.home / "state"
        self.state.mkdir()
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "DOTFILES_STATE_DIR": str(self.state),
            "DOTFILES_LOCK_TIMEOUT": "0",
        }
        self.status = self.home / "status"
        self.status.write_text("MM .zshrc\n")
        (self.home / ".zshrc").write_text("original\n")
        result = self.run_backup("create", "--status-file", str(self.status))
        self.backup_id = next(
            line.split("=", 1)[1]
            for line in result.stdout.splitlines()
            if line.startswith("backup_id=")
        )
        (self.home / ".zshrc").write_text("changed\n")

    def run_backup(self, *arguments, check=True, **environment):
        return subprocess.run(
            ["bash", str(ROOT / "scripts/backup.sh"), *arguments],
            env={**self.env, **environment},
            capture_output=True,
            text=True,
            check=check,
            timeout=8,
        )

    def test_mutations_refuse_a_held_bootstrap_lock_without_changes(self):
        with (self.state / "bootstrap.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            for arguments in (
                ("restore", self.backup_id, "--force"),
                ("prune", "0"),
                ("create", "--status-file", str(self.status)),
            ):
                with self.subTest(arguments=arguments):
                    result = self.run_backup(*arguments, check=False)
                    self.assertNotEqual(
                        result.returncode, 0, "mutation ignored the bootstrap lock"
                    )
                    self.assertIn("lock", result.stderr.lower())
                    self.assertEqual((self.home / ".zshrc").read_text(), "changed\n")
                    self.assertTrue((self.state / "backups" / self.backup_id).is_dir())

    def test_waiting_restore_proceeds_after_lock_is_released(self):
        with (self.state / "bootstrap.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            process = subprocess.Popen(
                [
                    "bash",
                    str(ROOT / "scripts/backup.sh"),
                    "restore",
                    self.backup_id,
                    "--force",
                ],
                env={**self.env, "DOTFILES_LOCK_TIMEOUT": "2"},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.addCleanup(lambda: process.poll() is None and process.kill())
            time.sleep(0.1)
            self.assertIsNone(process.poll(), "restore did not wait for the held lock")
            fcntl.flock(lock, fcntl.LOCK_UN)
        output, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, (output + error).decode())
        self.assertEqual((self.home / ".zshrc").read_text(), "original\n")

    def gated_create(self):
        mocks = self.home / "mocks"
        mocks.mkdir()
        gate = self.home / "release"
        ready = self.home / "ready"
        command = mocks / "cp"
        command.write_text(
            '#!/bin/sh\ntouch "$READY"\nwhile [ ! -e "$GATE" ]; do sleep 0.02; done\nexec /bin/cp "$@"\n'
        )
        command.chmod(0o755)
        process = subprocess.Popen(
            [
                "bash",
                str(ROOT / "scripts/backup.sh"),
                "create",
                "--status-file",
                str(self.status),
            ],
            env={
                **self.env,
                "PATH": str(mocks) + ":" + os.environ["PATH"],
                "GATE": str(gate),
                "READY": str(ready),
            },
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        self.addCleanup(
            lambda: process.poll() is None and os.killpg(process.pid, signal.SIGKILL)
        )
        deadline = time.monotonic() + 5
        while (
            not ready.exists()
            and time.monotonic() < deadline
            and process.poll() is None
        ):
            time.sleep(0.01)
        self.assertTrue(ready.exists(), "fixture never reached the snapshot copy")
        return process, gate

    def test_pending_snapshot_is_hidden_and_cannot_be_pruned(self):
        process, gate = self.gated_create()
        try:
            listed = self.run_backup("list").stdout.splitlines()
            self.assertEqual(listed, [self.backup_id])
            self.assertEqual(
                (self.state / "backups/latest").readlink().name, self.backup_id
            )
            self.assertNotEqual(
                self.run_backup("prune", "0", check=False).returncode, 0
            )
        finally:
            gate.touch()
            output, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, (output + error).decode())
        self.run_backup("verify", "latest")

    def test_interrupted_snapshot_is_unpublished_and_releases_lock(self):
        process, _ = self.gated_create()
        os.killpg(process.pid, signal.SIGTERM)
        process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.run_backup("list").stdout.splitlines(), [self.backup_id])
        self.assertFalse(list((self.state / "backups").glob(".pending-*")))
        self.run_backup("restore", self.backup_id, "--force")

    def test_failed_snapshot_keeps_latest_and_removes_pending_files(self):
        mocks = self.home / "mocks"
        mocks.mkdir()
        command = mocks / "cp"
        command.write_text("#!/bin/sh\nexit 37\n")
        command.chmod(0o755)
        result = self.run_backup(
            "create",
            "--status-file",
            str(self.status),
            check=False,
            PATH=str(mocks) + ":" + os.environ["PATH"],
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.run_backup("list").stdout.splitlines(), [self.backup_id])
        self.assertEqual(
            (self.state / "backups/latest").readlink().name, self.backup_id
        )
        self.assertFalse(list((self.state / "backups").glob(".pending-*")))

    def test_unverified_lock_delegation_does_not_bypass_a_held_lock(self):
        with (self.state / "bootstrap.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = self.run_backup(
                "restore",
                self.backup_id,
                "--force",
                check=False,
                DOTFILES_LOCK_OWNER_PID=str(os.getpid()),
                DOTFILES_LOCK_HELPER_PID=str(os.getpid()),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.home / ".zshrc").read_text(), "changed\n")

    def test_reconcile_respects_the_same_state_lock(self):
        with (self.state / "bootstrap.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = subprocess.run(
                [
                    "bash",
                    str(ROOT / "scripts/reconcile-packages.sh"),
                    "--sections",
                    "detect",
                ],
                env={**self.env, "DOTFILES_SOURCE_DIR": str(ROOT)},
                capture_output=True,
                text=True,
                timeout=8,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("state lock", result.stderr)

    def test_reconcile_hands_off_lock_to_its_installer_without_deadlock(self):
        runner = self.home / "run-section"
        runner.write_text(
            '#!/bin/sh\nflock -n "$DOTFILES_STATE_DIR/bootstrap.lock" sh -c \'echo installed > "$HOME/installed"\'\n'
        )
        runner.chmod(0o755)
        result = subprocess.run(
            [
                "bash",
                str(ROOT / "scripts/reconcile-packages.sh"),
                "--sections",
                "core",
                "--force",
            ],
            env={
                **self.env,
                "DOTFILES_SOURCE_DIR": str(ROOT),
                "DOTFILES_RUN_SECTION": str(runner),
            },
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.home / "installed").is_file())


if __name__ == "__main__":
    if not Path("/.dockerenv").exists():
        raise SystemExit("Run backup fixtures in Docker")
    unittest.main()
