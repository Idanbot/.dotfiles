#!/usr/bin/env python3
"""Regressions for the reusable graph and its fail-closed final check."""

import importlib.util
import json
import os
from pathlib import Path
import shlex
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
sys.path.insert(0, str(ROOT / "scripts/ci"))
import contracts  # noqa: E402

spec = importlib.util.spec_from_file_location(
    "ci_result", ROOT / "scripts/ci/result.py"
)
result = importlib.util.module_from_spec(spec)
spec.loader.exec_module(result)


def copy_contract_fixture(root):
    shutil.copytree(ROOT / ".github", root / ".github")
    (root / "tests").mkdir()
    shutil.copy2(ROOT / "tests/suites.json", root / "tests/suites.json")


class GraphTests(unittest.TestCase):
    def test_repository_contracts(self):
        contracts.check(ROOT)

    def test_updater_tests_run_once_in_contracts(self):
        workflow = contracts.load(ROOT / ".github/workflows/ci-checks.yml")
        matrix = workflow["jobs"]["contracts"]["strategy"]["matrix"]["include"]
        updater_tests = {
            "tests/test-package-metadata.sh": 0,
            "tests/test-update-packages.sh": 0,
            "tests/test-update-integrity-failure.sh": 0,
        }
        for entry in matrix:
            completed = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/ci/run-tests.py"),
                    entry["suite"],
                    "--root",
                    str(ROOT),
                    "--list",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            for line in completed.stdout.splitlines():
                argv = shlex.split(line)
                if argv[:2] != ["+", "bash"]:
                    continue
                path = str((ROOT / argv[2]).resolve().relative_to(ROOT))
                if path in updater_tests:
                    updater_tests[path] += 1
        self.assertEqual(updater_tests, dict.fromkeys(updater_tests, 1))

    def test_updater_scheduling_drift_is_rejected(self):
        for mutation in (
            "duplicate-matrix",
            "wsl-matrix",
            "missing-test",
            "behavior-test",
            "duplicate-check",
            "skipped-step",
            "ignored-step",
            "ignored-job",
        ):
            with (
                self.subTest(mutation=mutation),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                copy_contract_fixture(root)
                path = root / ".github/workflows/ci-checks.yml"
                workflow = contracts.load(path)
                job = workflow["jobs"]["contracts"]
                matrix = job["strategy"]["matrix"]["include"]
                upgrade = next(
                    entry for entry in matrix if entry["suite"] == "upgrades"
                )
                suite_step = next(
                    step for step in job["steps"] if "CI_SUITE" in step.get("env", {})
                )
                registry_path = root / "tests/suites.json"
                registry = json.loads(registry_path.read_text())
                updater = next(
                    entry
                    for entry in registry["tests"]
                    if entry["path"] == "tests/test-update-integrity-failure.sh"
                )
                if mutation == "duplicate-matrix":
                    matrix.append(upgrade.copy())
                elif mutation == "wsl-matrix":
                    upgrade.update(platform="wsl-simulated", wsl="true")
                elif mutation == "missing-test":
                    registry["tests"].remove(updater)
                elif mutation == "behavior-test":
                    updater["suite"] = "behavior"
                elif mutation == "duplicate-check":
                    registry["suites"]["upgrades"]["checks"] = [
                        ["bash", updater["path"], "."]
                    ]
                elif mutation == "skipped-step":
                    suite_step["if"] = "false"
                elif mutation == "ignored-step":
                    suite_step["continue-on-error"] = True
                else:
                    job["continue-on-error"] = True
                path.write_text(contracts.yaml.safe_dump(workflow))
                registry_path.write_text(json.dumps(registry))
                completed = subprocess.run(
                    [sys.executable, str(ROOT / "scripts/ci/contracts.py"), str(root)],
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(completed.returncode, 0, mutation)

    def test_graph_mutations_are_rejected(self):
        mutations = [
            ("ci.yml", lambda wf: wf["jobs"]["live"].update(needs=[])),
            ("ci.yml", lambda wf: wf["jobs"]["result"].update(needs=["checks"])),
            (
                "ci-live.yml",
                lambda wf: wf["jobs"]["heavy-e2e"].update(**{"if": "false"}),
            ),
            ("ci-live.yml", lambda wf: wf["jobs"]["base-e2e"].pop("timeout-minutes")),
            (
                "ci-outcome.yml",
                lambda wf: wf["jobs"]["classify"].update(
                    **{"if": "github.event.workflow_run.conclusion != 'success'"}
                ),
            ),
            (
                "ci-outcome.yml",
                lambda wf: wf["concurrency"].update(
                    group="ci-outcome-${{ github.event.workflow_run.id }}"
                ),
            ),
        ]
        for filename, mutate in mutations:
            with (
                self.subTest(filename=filename),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                copy_contract_fixture(root)
                path = root / ".github/workflows" / filename
                workflow = contracts.load(path)
                mutate(workflow)
                path.write_text(contracts.yaml.safe_dump(workflow))
                with self.assertRaises((AssertionError, KeyError)):
                    contracts.check(root)

    def test_classification_publication_drift_is_rejected(self):
        def publish(workflow):
            return next(
                step
                for step in workflow["jobs"]["classify"]["steps"]
                if step["name"] == "Publish classification check"
            )

        def checkout(workflow):
            return next(
                step
                for step in workflow["jobs"]["classify"]["steps"]
                if "checkout@" in step.get("uses", "")
            )

        mutations = [
            (
                "cancel-active-publication",
                lambda wf: wf["concurrency"].update(**{"cancel-in-progress": True}),
            ),
            (
                "untrusted-source",
                lambda wf: checkout(wf)["with"].update(
                    ref="${{ github.event.workflow_run.head_sha }}"
                ),
            ),
            (
                "write-source-permission",
                lambda wf: wf["jobs"]["classify"]["permissions"].update(
                    contents="write"
                ),
            ),
            (
                "missing-check-permission",
                lambda wf: wf["jobs"]["classify"]["permissions"].pop("checks"),
            ),
            (
                "wrong-source-run",
                lambda wf: publish(wf)["env"].update(RUN_ID="${{ github.run_id }}"),
            ),
            (
                "missing-attempt",
                lambda wf: publish(wf)["env"].pop("RUN_ATTEMPT"),
            ),
            (
                "bypassed-freshness-check",
                lambda wf: publish(wf).update(run="gh api --method POST check-runs"),
            ),
        ]
        for mutation, mutate in mutations:
            with (
                self.subTest(mutation=mutation),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                copy_contract_fixture(root)
                path = root / ".github/workflows/ci-outcome.yml"
                workflow = contracts.load(path)
                mutate(workflow)
                path.write_text(contracts.yaml.safe_dump(workflow))
                with self.assertRaises((AssertionError, KeyError)):
                    contracts.check(root)

    def test_platform_coverage_mutations_are_rejected(self):
        def step(workflow, identity):
            return next(
                entry
                for entry in workflow["jobs"]["arm64-smoke"]["steps"]
                if entry.get("id") == identity
            )

        def rewrite(workflow, identity, old, new):
            entry = step(workflow, identity)
            self.assertIn(old, entry["run"])
            entry["run"] = entry["run"].replace(old, new)

        mutations = [
            (
                "arm64-smoke.yml",
                "x64",
                lambda w: w["jobs"]["arm64-smoke"].update(
                    **{"runs-on": "ubuntu-24.04"}
                ),
            ),
            (
                "arm64-smoke.yml",
                "per-pr",
                lambda w: contracts.triggers(w).update(pull_request=None),
            ),
            (
                "arm64-smoke.yml",
                "weekly",
                lambda w: contracts.triggers(w).update(
                    schedule=[{"cron": "29 5 * * 1"}]
                ),
            ),
            (
                "arm64-smoke.yml",
                "private-billing",
                lambda w: w["jobs"]["arm64-smoke"].pop("if"),
            ),
            (
                "arm64-smoke.yml",
                "shared-manual-concurrency",
                lambda w: w["concurrency"].update(group="arm64-smoke"),
            ),
            (
                "arm64-smoke.yml",
                "full-matrix",
                lambda w: w["jobs"]["arm64-smoke"].update(
                    strategy={"matrix": {"profile": ["base", "full"]}}
                ),
            ),
            (
                "arm64-smoke.yml",
                "validator-target",
                lambda w: rewrite(w, "base", "--target base", "--target tests"),
            ),
            (
                "arm64-smoke.yml",
                "emulated-run",
                lambda w: rewrite(w, "smoke", "linux/arm64", "linux/amd64"),
            ),
            (
                "arm64-smoke.yml",
                "wrong-checksum",
                lambda w: rewrite(w, "smoke", "sha256_arm64", "sha256_amd64"),
            ),
            (
                "arm64-smoke.yml",
                "no-binary-execution",
                lambda w: rewrite(
                    w, "smoke", '"$HOME/.local/bin/$binary" --version', "true"
                ),
            ),
            (
                "arm64-smoke.yml",
                "hidden-failure",
                lambda w: step(w, "smoke").update(**{"continue-on-error": True}),
            ),
            (
                "arm64-smoke.yml",
                "skipped-smoke",
                lambda w: step(w, "smoke").update(**{"if": "false"}),
            ),
            (
                "arm64-smoke.yml",
                "cached-validators",
                lambda w: w["jobs"]["arm64-smoke"]["steps"].insert(
                    2, {"uses": "./.github/actions/validator-image"}
                ),
            ),
            (
                "arm64-smoke.yml",
                "unpinned-action",
                lambda w: w["jobs"]["arm64-smoke"]["steps"][1].update(
                    uses="actions/checkout@v7"
                ),
            ),
            (
                "wsl-e2e.yml",
                "scheduled-personal-wsl",
                lambda w: contracts.triggers(w).update(
                    schedule=[{"cron": "29 5 8 * *"}]
                ),
            ),
            (
                "wsl-e2e.yml",
                "push-wsl",
                lambda w: contracts.triggers(w).update(push=None),
            ),
            (
                "wsl-e2e.yml",
                "hosted-wsl",
                lambda w: w["jobs"]["wsl"].update(**{"runs-on": "windows-latest"}),
            ),
            (
                "wsl-e2e.yml",
                "missing-rootfs",
                lambda w: next(
                    s
                    for s in w["jobs"]["wsl"]["steps"]
                    if "test-wsl.ps1" in s.get("run", "")
                )["env"].pop("DOTFILES_WSL_ROOTFS"),
            ),
        ]
        for filename, mutation, mutate in mutations:
            with self.subTest(mutation=mutation):
                workflows = {
                    path.name: contracts.load(path)
                    for path in (ROOT / ".github/workflows").glob("*.yml")
                }
                mutate(workflows[filename])
                with self.assertRaises((AssertionError, KeyError, ValueError)):
                    contracts.platform_coverage(workflows)

    def test_arm64_smoke_pipeline_preserves_container_failure(self):
        workflow = contracts.load(ROOT / ".github/workflows/arm64-smoke.yml")
        smoke = next(
            s
            for s in workflow["jobs"]["arm64-smoke"]["steps"]
            if s.get("id") == "smoke"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mock = root / "docker"
            arguments = root / "arguments"
            mock.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$@" >"$MOCK_ARGUMENTS"\n'
                'exit "$MOCK_EXIT_CODE"\n'
            )
            mock.chmod(0o755)
            for status in (0, 37):
                with self.subTest(status=status):
                    completed = subprocess.run(
                        ["bash", "-euo", "pipefail", "-c", smoke["run"]],
                        cwd=root,
                        env={
                            **os.environ,
                            "PATH": f"{root}:{os.environ['PATH']}",
                            "GITHUB_WORKSPACE": directory,
                            "MOCK_ARGUMENTS": str(arguments),
                            "MOCK_EXIT_CODE": str(status),
                        },
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(completed.returncode, status, completed.stderr)
                    self.assertTrue((root / "artifacts/arm64/smoke.log").is_file())
                    argv = shlex.split(smoke["run"])
                    self.assertIn(argv[argv.index("-c") + 1], arguments.read_text())

    def test_cache_trust_or_freshness_drift_is_rejected(self):
        for action in ("validator-image", "audit-python"):
            for mutation in (
                "write-from-pr",
                "inverted-branch",
                "stale-restore",
                "credential-cache",
                "credential-save",
            ):
                with (
                    self.subTest(action=action, mutation=mutation),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    root = Path(directory)
                    copy_contract_fixture(root)
                    path = root / f".github/actions/{action}/action.yml"
                    data = contracts.load(path)
                    restore = next(
                        step
                        for step in data["runs"]["steps"]
                        if "cache/restore@" in step.get("uses", "")
                    )
                    save = next(
                        step
                        for step in data["runs"]["steps"]
                        if "cache/save@" in step.get("uses", "")
                    )
                    if mutation == "write-from-pr":
                        save["if"] = "always()"
                    elif mutation == "inverted-branch":
                        save["if"] = save["if"].replace(
                            "github.ref ==", "github.ref !="
                        )
                    elif mutation == "stale-restore":
                        restore["with"]["restore-keys"] = "validators-"
                    elif mutation == "credential-cache":
                        restore["with"]["path"] = "~/.ssh"
                    else:
                        save["with"]["path"] = "~/.aws"
                    path.write_text(contracts.yaml.safe_dump(data))
                    with self.assertRaises(AssertionError):
                        contracts.check(root)

    def test_required_results(self):
        self.assertEqual(result.failures({"checks": {"result": "success"}}), [])
        for conclusion in ("failure", "cancelled", "skipped", "timed_out", None):
            with self.subTest(conclusion=conclusion):
                self.assertTrue(result.failures({"checks": {"result": conclusion}}))

    def test_only_expected_skips_are_allowed(self):
        self.assertEqual(
            result.failures({"heavy": {"result": "skipped"}}, ["heavy"]), []
        )
        self.assertTrue(result.failures({"heavy": {"result": "failure"}}, ["heavy"]))
        self.assertTrue(result.failures({"base": {"result": "skipped"}}, ["heavy"]))

    def test_missing_required_result_is_fatal(self):
        completed = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/ci/result.py"),
                "--required",
                "checks",
                "live",
            ],
            env={
                **os.environ,
                "CI_NEEDS": json.dumps({"checks": {"result": "success"}}),
            },
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("live: missing", completed.stderr)

    def test_e2e_cleanup_is_scoped_to_its_own_project(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mock = root / "docker"
            calls = root / "calls"
            mock.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >>"$MOCK_CALLS"\n')
            mock.chmod(0o755)
            env = {
                **os.environ,
                "PATH": str(root) + ":" + os.environ["PATH"],
                "MOCK_CALLS": str(calls),
            }
            for _ in range(2):
                subprocess.run(
                    ["bash", str(ROOT / "scripts/ci/e2e.sh"), "base-native"],
                    cwd=root,
                    env=env,
                    check=True,
                )
            lines = calls.read_text().splitlines()
            self.assertEqual(len(lines), 4)
            projects = [line.split()[2] for line in lines]
            self.assertEqual(projects[0], projects[1])
            self.assertEqual(projects[2], projects[3])
            self.assertNotEqual(projects[0], projects[2])
            self.assertTrue(
                all(line.startswith("compose -p dotfiles-ci-") for line in lines)
            )

    def test_e2e_retains_logs_and_propagates_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mock = root / "docker"
            mock.write_text(
                '#!/bin/sh\ncase " $* " in\n'
                '  *" up "*) printf "compose stdout\\n"; printf "compose stderr\\n" >&2; exit "$UP_EXIT" ;;\n'
                '  *" down "*) printf "cleanup stdout\\n"; exit "$DOWN_EXIT" ;;\n'
                "  *) exit 99 ;;\nesac\n"
            )
            mock.chmod(0o755)
            for up, down, expected in (
                (0, 0, 0),
                (37, 0, 37),
                (0, 23, 1),
                (37, 23, 37),
            ):
                with self.subTest(up=up, down=down):
                    completed = subprocess.run(
                        ["bash", str(ROOT / "scripts/ci/e2e.sh"), "recovery"],
                        cwd=root,
                        env={
                            **os.environ,
                            "PATH": str(root) + ":" + os.environ["PATH"],
                            "UP_EXIT": str(up),
                            "DOWN_EXIT": str(down),
                        },
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(expected, completed.returncode, completed.stderr)
                    log = (root / "artifacts/recovery-compose.log").read_text()
                    self.assertIn("compose stdout", log)
                    self.assertIn("compose stderr", log)
                    self.assertIn(
                        "cleanup stdout",
                        (root / "artifacts/recovery-cleanup.log").read_text(),
                    )

    def test_acceptance_artifact_contract_mutations_are_rejected(self):
        for mutation in (
            "skip-diagnostics",
            "ignore-diagnostics",
            "always-performance",
            "ignore-performance",
        ):
            with (
                self.subTest(mutation=mutation),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                copy_contract_fixture(root)
                path = root / ".github/actions/e2e/action.yml"
                action = contracts.load(path)
                steps = action["runs"]["steps"]
                diagnostics = next(
                    step
                    for step in steps
                    if step["name"] == "Upload acceptance diagnostics"
                )
                performance = next(
                    step
                    for step in steps
                    if step["name"] == "Upload performance sample"
                )
                if mutation == "skip-diagnostics":
                    diagnostics["if"] = "success()"
                elif mutation == "ignore-diagnostics":
                    diagnostics["with"]["if-no-files-found"] = "ignore"
                elif mutation == "always-performance":
                    performance["if"] = "always()"
                else:
                    performance["with"]["if-no-files-found"] = "ignore"
                path.write_text(contracts.yaml.safe_dump(action))
                with self.assertRaises(AssertionError):
                    contracts.check(root)


@unittest.skipUnless(
    shutil.which("pwsh"), "PowerShell required for mocked WSL lifecycle"
)
class WslSafetyTests(unittest.TestCase):
    def run_harness(self, scenario):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "checkout with ' apostrophe"
            workspace.mkdir()
            rootfs = root / "ubuntu rootfs.tar"
            if scenario == "directory-rootfs":
                rootfs.mkdir()
            elif scenario != "missing-rootfs":
                rootfs.touch()
            mock = root / "mock-wsl.ps1"
            mock.write_text(r"""
param([string]$Target, [string]$Workspace, [string]$Rootfs, [string]$Scenario)
$ErrorActionPreference = "Stop"
$global:wslCalls = [System.Collections.Generic.List[object]]::new()
$global:wslRegistered = $false
$global:wslDistroName = $null
$global:wslInstallPath = $null
$global:wslPathCount = 0
function wsl.exe {
  $arguments = @($args)
  $stdin = @($input) -join "`n"
  $global:wslCalls.Add(@{arguments = $arguments; stdin = $stdin})
  $global:LASTEXITCODE = 0
  switch ($arguments[0]) {
    "--list" {
      if ($Scenario -eq "list-failure") { $global:LASTEXITCODE = 20; return }
      if ($Scenario -eq "cleanup-list-failure" -and $global:wslDistroName) {
        $global:LASTEXITCODE = 20
        return
      }
      ("Ubuntu-24.04".ToCharArray() -join "`0")
      if ($Scenario -eq "existing-name") {
        Get-Variable -Name distro -Scope 2 -ValueOnly
      }
      if ($global:wslRegistered) { ($global:wslDistroName.ToCharArray() -join "`0") }
      return
    }
    "--import" {
      $global:wslDistroName = $arguments[1]
      $global:wslInstallPath = $arguments[2]
      if ($Scenario -ne "import-failure") { $global:wslRegistered = $true }
      if ($Scenario -in @("import-failure", "partial-import-failure")) {
        $global:LASTEXITCODE = 21
      }
      return
    }
    "--unregister" {
      if ($Scenario -eq "cleanup-failure") { $global:LASTEXITCODE = 22; return }
      if ($Scenario -eq "cleanup-removes-directory") {
        Remove-Item -LiteralPath $global:wslInstallPath -Recurse -Force
      }
      $global:wslRegistered = $false
      return
    }
    "--distribution" {
      if ($arguments[5] -eq "wslpath") {
        $global:wslPathCount++
        if (($Scenario -eq "first-path-failure" -and $global:wslPathCount -eq 1) -or
            ($Scenario -eq "second-path-failure" -and $global:wslPathCount -eq 2)) {
          $global:LASTEXITCODE = 23
          return
        }
        if ($global:wslPathCount -eq 1) { "/mnt/checkout with ' apostrophe" }
        else { "/mnt/checkout with ' apostrophe/artifacts/wsl" }
      } elseif ($arguments[5] -eq "bash") {
        if (($Scenario -eq "setup-failure" -and $arguments[3] -eq "root") -or
            ($Scenario -eq "bootstrap-failure" -and $arguments[3] -eq "dotfiles-e2e")) {
          $global:LASTEXITCODE = 24
        }
      } else { throw "Unexpected WSL executable" }
      return
    }
    default { throw "Unexpected WSL invocation" }
  }
}
$failure = $null
try {
  $tokens = $null
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    $Target, [ref]$tokens, [ref]$parseErrors
  ) | Out-Null
  if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
  if ($Scenario -eq "env-rootfs") {
    $env:DOTFILES_WSL_ROOTFS = $Rootfs
    & $Target -Workspace $Workspace
  } else {
    & $Target -Workspace $Workspace -Rootfs $Rootfs
  }
} catch { $failure = "$($_.Exception.Message) at $($_.ScriptStackTrace)" }
@{
  calls = $global:wslCalls.ToArray()
  failure = $failure
  registered = $global:wslRegistered
  installDirExists = ($global:wslInstallPath -and (Test-Path -LiteralPath $global:wslInstallPath))
} | ConvertTo-Json -Depth 8 -Compress
""")
            completed = subprocess.run(
                [
                    "pwsh",
                    "-NoLogo",
                    "-NoProfile",
                    "-File",
                    str(mock),
                    "-Target",
                    str(ROOT / "tests/e2e/test-wsl.ps1"),
                    "-Workspace",
                    str(workspace),
                    "-Rootfs",
                    str(rootfs),
                    "-Scenario",
                    scenario,
                ],
                env={**os.environ, "TMPDIR": directory},
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            )
            self.assertFalse(completed.stderr, completed.stderr)
            report = json.loads(completed.stdout)
            for call in report["calls"]:
                if call["arguments"][0] == "--distribution":
                    self.assertEqual(call["arguments"][2], "--user")
                    self.assertIn(call["arguments"][3], ("root", "dotfiles-e2e"))
                    self.assertRegex(
                        call["arguments"][1], r"^dotfiles-e2e-[0-9a-f]{32}$"
                    )
                if call["stdin"]:
                    subprocess.run(
                        ["bash", "-n"],
                        input=call["stdin"] + "\r\n",
                        text=True,
                        check=True,
                    )
            return report

    def test_disposable_distro_and_explicit_users(self):
        for scenario in ("success", "env-rootfs", "cleanup-removes-directory"):
            with self.subTest(scenario=scenario):
                report = self.run_harness(scenario)
                self.assertIsNone(report["failure"])
                self.assertFalse(report["registered"])
                self.assertFalse(report["installDirExists"])
                calls = report["calls"]
                imported = next(
                    c["arguments"] for c in calls if c["arguments"][0] == "--import"
                )
                self.assertRegex(imported[1], r"^dotfiles-e2e-[0-9a-f]{32}$")
                self.assertEqual(imported[-2:], ["--version", "2"])
                unregistered = next(
                    c["arguments"] for c in calls if c["arguments"][0] == "--unregister"
                )
                self.assertEqual(unregistered, ["--unregister", imported[1]])
                executions = [c for c in calls if c["arguments"][0] == "--distribution"]
                self.assertEqual(len(executions), 4)
                self.assertTrue(
                    all(c["arguments"][1] == imported[1] for c in executions)
                )
                setup, bootstrap = executions[-2:]
                self.assertEqual(setup["arguments"][3], "root")
                self.assertNotIn("--yes", setup["stdin"])
                self.assertIn("useradd --create-home", setup["stdin"])
                self.assertIn("microsoft.*wsl2", setup["stdin"])
                self.assertEqual(bootstrap["arguments"][3], "dotfiles-e2e")
                self.assertEqual(
                    bootstrap["arguments"][-3:],
                    [
                        "--",
                        "/mnt/checkout with ' apostrophe",
                        "/mnt/checkout with ' apostrophe/artifacts/wsl",
                    ],
                )
                self.assertIn('"$HOME" == /home/dotfiles-e2e', bootstrap["stdin"])
                self.assertIn(
                    "--profile base --conflict-policy backup --yes", bootstrap["stdin"]
                )
                self.assertNotIn("/mnt/checkout", bootstrap["stdin"])

    def test_shell_guards_reject_personal_context_before_sudo(self):
        report = self.run_harness("success")
        script = next(
            c["stdin"]
            for c in report["calls"]
            if c["arguments"][0] == "--distribution"
            and c["arguments"][3] == "dotfiles-e2e"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "id").write_text('#!/bin/sh\nprintf "%s\\n" "$MOCK_USER"\n')
            (root / "sudo").write_text('#!/bin/sh\ntouch "$SUDO_CALLED"\nexit 99\n')
            (root / "id").chmod(0o755)
            (root / "sudo").chmod(0o755)
            for distro, user in (
                ("Ubuntu-24.04", "dotfiles-e2e"),
                ("dotfiles-e2e-test", "personal-user"),
                ("dotfiles-e2e-test", "dotfiles-e2e"),
            ):
                with self.subTest(distro=distro, user=user):
                    completed = subprocess.run(
                        ["bash", "-s", "--", directory, directory],
                        input=script,
                        env={
                            **os.environ,
                            "PATH": f"{root}:{os.environ['PATH']}",
                            "HOME": directory,
                            "WSL_DISTRO_NAME": distro,
                            "MOCK_USER": user,
                            "SUDO_CALLED": str(root / "called"),
                        },
                        text=True,
                        capture_output=True,
                        timeout=10,
                    )
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertFalse((root / "called").exists())

    def test_refuses_missing_rootfs_or_existing_distro(self):
        for scenario in (
            "missing-rootfs",
            "directory-rootfs",
            "list-failure",
            "existing-name",
        ):
            with self.subTest(scenario=scenario):
                report = self.run_harness(scenario)
                self.assertIsNotNone(report["failure"])
                self.assertTrue(
                    all(c["arguments"][0] == "--list" for c in report["calls"])
                )

    def test_failures_stop_bootstrap_and_always_dispose_owned_distro(self):
        for scenario in (
            "import-failure",
            "partial-import-failure",
            "first-path-failure",
            "second-path-failure",
            "setup-failure",
            "bootstrap-failure",
        ):
            with self.subTest(scenario=scenario):
                report = self.run_harness(scenario)
                self.assertIsNotNone(report["failure"])
                self.assertIn("failed with exit code", report["failure"])
                self.assertFalse(report["registered"])
                self.assertFalse(report["installDirExists"])
                calls = report["calls"]
                cleanup = [c for c in calls if c["arguments"][0] == "--unregister"]
                self.assertEqual(len(cleanup), 0 if scenario == "import-failure" else 1)
                bootstrap = [
                    c
                    for c in calls
                    if c["arguments"][0] == "--distribution"
                    and c["arguments"][3] == "dotfiles-e2e"
                ]
                self.assertEqual(
                    len(bootstrap), 1 if scenario == "bootstrap-failure" else 0
                )

    def test_cleanup_failure_is_not_hidden_or_disk_deleted(self):
        for scenario, command in (
            ("cleanup-failure", "--unregister"),
            ("cleanup-list-failure", "--list"),
        ):
            with self.subTest(scenario=scenario):
                report = self.run_harness(scenario)
                self.assertIn(command, report["failure"])
                self.assertTrue(report["registered"])
                self.assertTrue(report["installDirExists"])


if __name__ == "__main__":
    unittest.main()
