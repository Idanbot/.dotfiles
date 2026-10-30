#!/usr/bin/env python3
"""Offline package-manager ownership and recovery tests with synthetic homes."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MANAGER = r"""#!/usr/bin/python3
import json, os, shutil, sys
from pathlib import Path
manager = Path(sys.argv[0]).name
args = sys.argv[1:]
home = Path(os.environ["HOME"])
tools = Path(os.environ["UV_TOOL_DIR"])
bins = Path(os.environ["UV_TOOL_BIN_DIR"])
if args == ["tool", "dir"]:
    print(tools); sys.exit(0)
if args == ["tool", "dir", "--bin"]:
    print(bins); sys.exit(0)
if args == ["python", "dir"]:
    print(os.environ["UV_PYTHON_INSTALL_DIR"]); sys.exit(0)
if args == ["python", "dir", "--bin"]:
    print(bins); sys.exit(0)
with open(os.environ["CALLS"], "a") as stream:
    stream.write(json.dumps([manager, *args]) + "\n")
if os.environ.get("NOISE"):
    print("package manager progress output")
    print("WARNING: example token=do-not-log-this")
if "install" in args and "uninstall" not in args:
    spec = args[-1]
    package, version = spec.rsplit("==" if manager == "uv" else "@", 1)
    prefix = Path(args[args.index("--prefix") + 1]) if manager == "npm" else tools
    target = prefix / "lib/node_modules" / package if manager == "npm" else tools / package
    binary_dir = prefix / "bin" if manager == "npm" else bins
    names = os.environ.get("COMMANDS", "review-cli,review-helper").split(",")
    for name in names:
        link = binary_dir / name
        if (link.exists() or link.is_symlink()) and "--force" not in args:
            if not link.is_symlink() or link.resolve() != target / "bin" / name:
                sys.exit(8)
    if os.environ.get("FAIL") == "before": sys.exit(9)
    (target / "bin").mkdir(parents=True, exist_ok=True)
    binary_dir.mkdir(parents=True, exist_ok=True)
    for name in names:
        command = target / "bin" / name
        command.write_text("#!/bin/sh\n" + ("exit 37\n" if os.environ.get("FAIL") == "probe" else "echo " + version + "\n"))
        command.chmod(0o755)
        link = binary_dir / name
        link.unlink(missing_ok=True)
        link.symlink_to(command)
    if manager == "uv":
        entries = [f'{{name = "{name}", install-path = {json.dumps(str(binary_dir / name))}}}' for name in names]
        (target / "uv-receipt.toml").write_text('[tool]\nrequirements = [{name = "' + package + '"}]\nentrypoints = [' + ','.join(entries) + ']\n')
        metadata = target / "lib/python3.12/site-packages" / (package + ".dist-info/METADATA")
        metadata.parent.mkdir(parents=True, exist_ok=True)
        metadata.write_text("Name: " + package + "\nVersion: " + os.environ.get("METADATA_VERSION", version) + "\n")
    else:
        (target / "package.json").write_text(json.dumps({"name": package, "version": version, "bin": {name: "bin/" + name for name in names}}))
    if os.environ.get("FAIL") == "after": sys.exit(9)
    if os.environ.get("FAIL") in ("INT", "TERM", "HUP"):
        import signal
        os.kill(os.getppid(), getattr(signal, "SIG" + os.environ["FAIL"]))
elif "uninstall" in args:
    package = args[-1]
    if manager == "npm":
        target = Path(args[args.index("--prefix") + 1]) / "lib/node_modules" / package
    elif manager == "omp":
        target = home / ".omp/plugins/node_modules" / package
    elif args[:2] == ["python", "uninstall"]:
        target = Path(os.environ["UV_PYTHON_INSTALL_DIR"]) / package
    else:
        target = tools / package
    if os.environ.get("FAIL") == "uninstall": sys.exit(9)
    if os.environ.get("FAIL") != "no-remove": shutil.rmtree(target, ignore_errors=True)
else:
    sys.exit(2)
"""


class ManagerSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="manager home ")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.bin = self.home / ".local/bin"
        self.bin.mkdir(parents=True)
        self.mocks = self.home / "mocks"
        self.mocks.mkdir()
        for manager in ("npm", "uv", "omp"):
            executable = self.mocks / manager
            executable.write_text(MANAGER)
            executable.chmod(0o755)
        self.state = self.home / "state"
        self.calls = self.home / "calls.jsonl"
        self.tools = self.home / ".local/share/uv/tools"
        self.prefix = self.home / ".local/share/npm"
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "DOTFILES_SOURCE_DIR": str(ROOT),
            "DOTFILES_STATE_DIR": str(self.state),
            "DOTFILES_NPM_PREFIX": str(self.prefix),
            "UV_TOOL_DIR": str(self.tools),
            "UV_TOOL_BIN_DIR": str(self.bin),
            "UV_PYTHON_INSTALL_DIR": str(self.home / ".local/share/uv/python"),
            "PATH": f"{self.mocks}:{self.bin}:/usr/bin:/bin",
            "CALLS": str(self.calls),
            "DOTFILES_VERSION_PLAN": str(self.home / "versions.json"),
            "NO_COLOR": "1",
        }
        (self.home / "versions.json").write_text('{"tools":{}}\n')

    def shell(self, script, check=True, **environment):
        return subprocess.run(
            [
                "bash",
                "-c",
                'set -euo pipefail; source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; '
                'source "$DOTFILES_SOURCE_DIR/scripts/install-uv-tool.sh"; ' + script,
            ],
            env={**self.env, **environment},
            capture_output=True,
            text=True,
            check=check,
            timeout=15,
        )

    def seed(self, manager):
        if manager == "npm":
            subprocess.run(
                [
                    str(self.mocks / manager),
                    "install",
                    "--prefix",
                    str(self.prefix),
                    "review-package@1.0.0",
                ],
                env=self.env,
                check=True,
            )
            self.target = self.prefix / "lib/node_modules/review-package"
            (self.bin / "review-cli").symlink_to(self.prefix / "bin/review-cli")
        else:
            subprocess.run(
                [str(self.mocks / manager), "tool", "install", "review-package==1.0.0"],
                env=self.env,
                check=True,
            )
            self.target = self.tools / "review-package"
        self.shell(
            "record_install review-cli 1.0.0 " + manager + ':review-package "$TARGET"; '
            'record_install review-cli 1.0.0 symlink "$HOME/.local/bin/review-cli"',
            TARGET=str(self.target),
        )
        self.calls.unlink()

    def receipt_state(self):
        return {
            str(path.relative_to(self.state)): path.read_bytes()
            for path in self.state.rglob("*")
            if path.is_file() and not path.name.endswith(".lock")
        }

    def manager_calls(self):
        return (
            [json.loads(line) for line in self.calls.read_text().splitlines()]
            if self.calls.exists()
            else []
        )

    def uninstall(self, dry_run=False, check=True, **environment):
        return self.shell(
            'bash "$DOTFILES_SOURCE_DIR/scripts/uninstall-tool.sh" '
            + ("--dry-run " if dry_run else "")
            + "review-cli",
            check=check,
            **environment,
        )

    def test_npm_preserves_modified_payload_behind_owned_shim(self):
        self.seed("npm")
        payload = self.target / "bin/review-cli"
        payload.write_text(payload.read_text() + "# user change\n")
        before = payload.read_bytes(), self.receipt_state()
        result = self.shell("npm_install_global review-package 2.0.0 review-cli")
        self.assertFalse(
            self.calls.exists(), "npm mutated a modified package behind an owned shim"
        )
        self.assertEqual((payload.read_bytes(), self.receipt_state()), before)
        self.assertIn("Preserv", result.stdout + result.stderr)

    def test_uninstall_rejects_modified_uv_package_before_removing_any_command(self):
        self.seed("uv")
        payload = self.target / "bin/review-cli"
        payload.write_text(payload.read_text() + "# user change\n")
        before = payload.read_bytes(), self.receipt_state()
        result = self.shell(
            'bash "$DOTFILES_SOURCE_DIR/scripts/uninstall-tool.sh" review-cli',
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(
            self.calls.exists(), "uninstall invoked a manager for a modified package"
        )
        self.assertTrue((self.bin / "review-cli").is_symlink())
        self.assertEqual((payload.read_bytes(), self.receipt_state()), before)

    def test_uv_failed_probe_restores_previous_environment_commands_and_receipts(self):
        self.seed("uv")
        before = self.receipt_state()
        result = self.shell(
            "install_uv_tool review-cli review-package 2.0.0", check=False, FAIL="probe"
        )
        self.assertNotEqual(result.returncode, 0)
        version = subprocess.check_output(
            [str(self.bin / "review-cli"), "--version"], text=True
        )
        self.assertEqual(
            version.strip(), "1.0.0", "failed upgrade left the active tool broken"
        )
        self.assertEqual(self.receipt_state(), before)

    def test_npm_refuses_unowned_payload_even_with_named_shim_replacement(self):
        self.seed("npm")
        self.shell('forget_install review-cli "$TARGET"', TARGET=str(self.target))
        before = self.receipt_state()
        self.shell(
            "npm_install_global review-package 2.0.0 review-cli",
            DOTFILES_REPLACE_BINARIES="review-cli",
        )
        self.assertEqual(self.manager_calls(), [])
        self.assertEqual(self.receipt_state(), before)

    def test_npm_rechecks_payload_after_acquiring_lock(self):
        self.seed("npm")
        self.shell(
            "eval \"$(declare -f managed_operation_lock | sed '1s/managed_operation_lock/original_lock/')\"; "
            'managed_operation_lock() { original_lock; echo edited >> "$TARGET/bin/review-cli"; }; '
            "npm_install_global review-package 2.0.0 review-cli",
            TARGET=str(self.target),
        )
        self.assertEqual(self.manager_calls(), [])
        self.assertIn("edited", (self.target / "bin/review-cli").read_text())

    def test_upgrade_and_second_pass_preserve_unrelated_packages_and_counters(self):
        self.seed("npm")
        unrelated = self.prefix / "lib/node_modules/unrelated"
        unrelated.mkdir()
        (unrelated / "keep").write_text("unrelated package")
        result = self.shell(
            "npm_install_global review-package 2.0.0 review-cli; "
            "npm_install_global review-package 2.0.0 review-cli; "
            "[[ $_INSTALLED == 1 && $_SKIPPED == 1 && $_FAILED == 0 ]]"
        )
        self.assertEqual(len(self.manager_calls()), 1)
        self.assertEqual((unrelated / "keep").read_text(), "unrelated package")
        self.assertIn("matches repository", result.stdout)
        self.shell(
            'assert_owned_target "$TARGET"; assert_owned_target "$HOME/.local/bin/review-cli"',
            TARGET=str(self.target),
        )

    def test_current_version_skips_tree_hashing_snapshots_and_probes(self):
        self.seed("uv")
        (self.target / "bin/review-cli").write_text("#!/bin/sh\nexit 38\n")
        before = self.receipt_state()
        self.shell(
            "managed_target_digest() { exit 40; }; snapshot_publication() { exit 41; }; "
            "install_uv_tool review-cli review-package 1.0.0"
        )
        self.assertEqual(self.manager_calls(), [])
        self.assertEqual(self.receipt_state(), before)

    def test_uv_manager_directories_are_resolved_once_per_run(self):
        self.seed("uv")
        self.shell(
            'uv() { if [[ "$*" == "tool dir" || "$*" == "tool dir --bin" ]]; then '
            'echo query >> "$HOME/queries"; fi; command uv "$@"; }; '
            "install_uv_tool review-cli review-package 2.0.0; "
            "install_uv_tool review-cli review-package 2.0.0; "
            '[[ $(wc -l < "$HOME/queries") == 2 ]]'
        )

    def test_uv_normalized_date_version_installs_and_converges(self):
        self.shell(
            "install_uv_tool review-cli review-package 2026.08.19; "
            "install_uv_tool review-cli review-package 2026.08.19; "
            "[[ $_INSTALLED == 1 && $_SKIPPED == 1 && $_FAILED == 0 ]]",
            METADATA_VERSION="2026.8.19",
        )
        self.assertEqual(len(self.manager_calls()), 1)

    def test_uv_install_failures_restore_all_previous_paths_and_receipts(self):
        self.seed("uv")
        before = self.receipt_state()
        for failure in ("before", "after", "probe", "INT", "TERM", "HUP"):
            with self.subTest(failure=failure):
                result = self.shell(
                    "install_uv_tool review-cli review-package 2.0.0",
                    check=False,
                    FAIL=failure,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(
                    subprocess.check_output(
                        [str(self.bin / "review-cli")], text=True
                    ).strip(),
                    "1.0.0",
                )
                self.assertEqual(
                    subprocess.check_output(
                        [str(self.bin / "review-helper")], text=True
                    ).strip(),
                    "1.0.0",
                )
                self.assertEqual(self.receipt_state(), before)
                self.assertFalse(list(self.state.glob(".manager-transaction.*")))

    def test_uv_ledger_failure_rolls_back_and_preserves_unrelated_receipts(self):
        self.seed("uv")
        before = self.receipt_state()
        result = self.shell(
            "record_install() { return 1; }; install_uv_tool review-cli review-package 2.0.0",
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.receipt_state(), before)
        self.assertEqual(
            subprocess.check_output([str(self.bin / "review-cli")], text=True).strip(),
            "1.0.0",
        )

    def test_uv_failed_upgrade_removes_only_new_native_commands(self):
        self.seed("uv")
        unrelated = self.bin / "keep-cli"
        unrelated.write_text("keep")
        result = self.shell(
            "install_uv_tool review-cli review-package 2.0.0",
            check=False,
            FAIL="probe",
            COMMANDS="review-cli,review-helper,new-helper",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.bin / "new-helper").exists())
        self.assertFalse((self.bin / "new-helper").is_symlink())
        self.assertEqual(unrelated.read_text(), "keep")

    def test_uv_does_not_force_overwrite_new_entrypoint_collisions(self):
        self.seed("uv")
        collision = self.bin / "new-helper"
        collision.write_text("user command")
        before = self.receipt_state()
        result = self.shell(
            "install_uv_tool review-cli review-package 2.0.0",
            check=False,
            COMMANDS="review-cli,review-helper,new-helper",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("--force", self.manager_calls()[0])
        self.assertEqual(collision.read_text(), "user command")
        self.assertEqual(self.receipt_state(), before)

    def test_failed_rollback_retains_private_recovery_payload(self):
        self.seed("uv")
        result = self.shell(
            'cp() { [[ "$*" != *"/previous "* ]] || return 1; command cp "$@"; }; '
            "install_uv_tool review-cli review-package 2.0.0",
            check=False,
            FAIL="probe",
        )
        self.assertNotEqual(result.returncode, 0)
        recovery = list(self.state.glob(".manager-transaction.*"))
        self.assertEqual(len(recovery), 1)
        self.assertEqual(recovery[0].stat().st_mode & 0o777, 0o700)
        self.assertTrue(list(recovery[0].rglob("review-cli")))
        self.assertIn(str(self.target), (recovery[0] / "targets").read_text())
        self.assertIn("Recovery files retained", result.stderr)

    def test_native_uninstall_is_once_per_package_with_custom_prefix_and_dry_run_parity(
        self,
    ):
        self.prefix = self.home / "custom npm prefix"
        self.env["DOTFILES_NPM_PREFIX"] = str(self.prefix)
        self.seed("npm")
        self.shell(
            'record_install review-cli 1.0.0 npm:review-package "$TARGET"',
            TARGET=str(self.prefix / "bin/review-helper"),
        )
        before = self.receipt_state()
        self.uninstall(dry_run=True)
        self.assertEqual(self.manager_calls(), [])
        self.assertEqual(self.receipt_state(), before)
        self.uninstall()
        calls = self.manager_calls()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][calls[0].index("--prefix") + 1], str(self.prefix))
        self.assertFalse((self.bin / "review-cli").is_symlink())
        self.assertNotIn("review-cli\t", (self.state / "installed.tsv").read_text())

    def test_uninstall_rejects_redirected_roots_and_bindings_without_side_effects(self):
        self.seed("npm")
        before = self.receipt_state()
        for modification in ("binding", "root"):
            with self.subTest(modification=modification):
                if modification == "binding":
                    link = self.prefix / "bin/review-helper"
                    link.unlink()
                    link.symlink_to("/usr/bin/true")
                else:
                    relocated = self.home / "relocated"
                    self.prefix.rename(relocated)
                    self.prefix.symlink_to(relocated)
                for dry_run in (True, False):
                    self.assertNotEqual(
                        self.uninstall(dry_run=dry_run, check=False).returncode, 0
                    )
                self.assertEqual(self.manager_calls(), [])
                self.assertEqual(self.receipt_state(), before)

    def test_modified_payload_rejects_dry_run_and_real_uninstall_before_shim_deletion(
        self,
    ):
        self.seed("npm")
        (self.target / "package.json").write_text('{"name":"other","version":"1.0.0"}')
        before = self.receipt_state()
        for dry_run in (True, False):
            self.assertNotEqual(
                self.uninstall(dry_run=dry_run, check=False).returncode, 0
            )
        self.assertTrue((self.bin / "review-cli").is_symlink())
        self.assertEqual(self.manager_calls(), [])
        self.assertEqual(self.receipt_state(), before)

    def test_legacy_python_receipts_cannot_authorize_manager_removal(self):
        self.shell("record_install review-cli 1.0.0 uv-python 3.14.9")
        for dry_run in (True, False):
            self.assertNotEqual(
                self.uninstall(dry_run=dry_run, check=False).returncode, 0
            )
        self.assertEqual(self.manager_calls(), [])

    def test_python_and_omp_validate_payloads_before_native_removal(self):
        cases = (
            ("python", "cpython-3.14.9-linux-x86_64-gnu", "uv-python"),
            ("omp", "@example/plugin", "omp:@example/plugin"),
        )
        for kind, package, owner in cases:
            with self.subTest(kind=kind):
                target = (
                    Path(self.env["UV_PYTHON_INSTALL_DIR"]) / package
                    if kind == "python"
                    else self.home / ".omp/plugins/node_modules" / package
                )
                target.mkdir(parents=True)
                manifest = target / "package.json"
                manifest.write_text(json.dumps({"name": package, "version": "1.0.0"}))
                self.shell(
                    'record_install review-cli 1.0.0 "$OWNER" "$TARGET"',
                    OWNER=owner,
                    TARGET=str(target),
                )
                original = manifest.read_bytes()
                manifest.write_bytes(original + b"\n")
                before = self.receipt_state()
                self.assertNotEqual(self.uninstall(check=False).returncode, 0)
                self.assertEqual(self.manager_calls(), [])
                self.assertEqual(self.receipt_state(), before)
                manifest.write_bytes(original)
                self.uninstall(dry_run=True)
                self.uninstall()
                self.assertFalse(target.exists())
                self.calls.unlink()

    def test_manager_failure_or_incomplete_uninstall_keeps_receipts(self):
        self.seed("uv")
        before = self.receipt_state()
        for failure in ("uninstall", "no-remove"):
            with self.subTest(failure=failure):
                self.assertNotEqual(
                    self.uninstall(check=False, FAIL=failure).returncode, 0
                )
                self.assertEqual(self.receipt_state(), before)

    def test_shared_uvx_cache_is_never_removed(self):
        shared = self.home / ".cache/uv"
        shared.mkdir(parents=True)
        (shared / "keep").write_text("shared")
        self.shell('record_install review-cli 1.0.0 uvx "$TARGET"', TARGET=str(shared))
        self.uninstall()
        self.assertEqual((shared / "keep").read_text(), "shared")
        self.assertEqual(self.manager_calls(), [])

    def test_full_install_native_output_is_quiet_redacted_and_retained_in_log(self):
        self.seed("uv")
        log = self.home / "bootstrap.log"
        log.touch(mode=0o600)
        result = self.shell(
            "install_uv_tool review-cli review-package 2.0.0",
            NOISE="1",
            DOTFILES_MANAGER_LOG=str(log),
        )
        self.assertNotIn("package manager progress", result.stdout)
        self.assertIn("WARNING:", result.stdout)
        self.assertIn("package manager progress", log.read_text())
        self.assertNotIn(
            "do-not-log-this", result.stdout + result.stderr + log.read_text()
        )
        self.assertIn("[REDACTED]", log.read_text())

    def test_quiet_failures_and_interruptions_still_roll_back_and_log_errors(self):
        self.seed("uv")
        for failure in ("after", "probe", "INT", "TERM", "HUP"):
            with self.subTest(failure=failure):
                log = self.home / f"bootstrap-{failure}.log"
                log.touch(mode=0o600)
                result = self.shell(
                    "install_uv_tool review-cli review-package 2.0.0",
                    check=False,
                    NOISE="1",
                    FAIL=failure,
                    DOTFILES_MANAGER_LOG=str(log),
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(
                    subprocess.check_output(
                        [str(self.bin / "review-cli")], text=True
                    ).strip(),
                    "1.0.0",
                )
                self.assertNotIn(
                    "do-not-log-this", result.stdout + result.stderr + log.read_text()
                )
                self.assertIn("package manager progress", log.read_text())
                self.assertIn("[REDACTED]", log.read_text())

    def test_native_children_do_not_inherit_the_ownership_lock(self):
        self.shell(
            "managed_operation run_manager bash -c 'for fd in /proc/$$/fd/*; do "
            '[[ "$(readlink "$fd")" != "$DOTFILES_STATE_DIR/ownership.lock" ]] || exit 29; done\'; '
            'flock -n "$DOTFILES_STATE_DIR/ownership.lock" true'
        )

    def test_unresponsive_external_version_probe_is_bounded_and_preserved(self):
        self.seed("uv")
        active = self.mocks / "review-cli"
        active.write_text("#!/bin/sh\nsleep 30\n")
        active.chmod(0o755)
        result = self.shell(
            'timeout() { command timeout 0.05 "${@:2}"; }; '
            "install_uv_tool review-cli review-package 2.0.0"
        )
        self.assertIn("unknown version", result.stdout)
        self.assertEqual(self.manager_calls(), [])

    def test_wrong_manager_prefix_and_custom_omp_root_cannot_authorize_removal(self):
        self.seed("npm")
        before = self.receipt_state()
        result = self.uninstall(
            check=False, DOTFILES_NPM_PREFIX=str(self.home / "different-prefix")
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.manager_calls(), [])
        self.assertEqual(self.receipt_state(), before)
        target = self.home / "custom-plugins/node_modules/example"
        target.mkdir(parents=True)
        (target / "package.json").write_text('{"name":"example","version":"1.0.0"}')
        self.shell(
            'forget_install review-cli; record_install review-cli 1.0.0 omp:example "$TARGET"',
            TARGET=str(target),
        )
        result = self.uninstall(
            check=False, DOTFILES_OMP_PLUGIN_ROOT=str(self.home / "custom-plugins")
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(target.exists())
        self.assertEqual(self.manager_calls(), [])


if __name__ == "__main__":
    if not Path("/.dockerenv").exists():
        raise SystemExit("Run these fixtures inside Docker")
    unittest.main()
