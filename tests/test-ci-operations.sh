#!/usr/bin/env bash
# Parse workflow semantics rather than depending on inline test filenames.
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
python3 "$ROOT/scripts/ci/contracts.py" "$ROOT"

# Parse both the hosted Bash and the quoted container payload without installing.
python3 - "$ROOT" <<'PY'
from pathlib import Path
import json
import os
import shlex
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(sys.argv[1]) / "scripts/ci"))
import contracts

root = Path(sys.argv[1])
workflow = contracts.load(root / ".github/workflows/ci-checks.yml")
suite_step = next(
    step for step in workflow["jobs"]["contracts"]["steps"]
    if "CI_SUITE" in step.get("env", {})
)
with tempfile.TemporaryDirectory() as directory:
    fixture = Path(directory)
    helper = fixture / "scripts/ci/docker-suite.sh"
    helper.parent.mkdir(parents=True)
    helper.write_text('#!/bin/sh\nprintf "%s %s\\n" "$1" "$DOTFILES_WSL"\n'
                      'exit "$SUITE_EXIT_CODE"\n')
    helper.chmod(0o755)
    for status in (0, 37):
        completed = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", suite_step["run"]], cwd=fixture,
            env={**os.environ, "CI_SUITE": "upgrades", "DOTFILES_WSL": "false",
                 "SUITE_EXIT_CODE": str(status)}, capture_output=True, text=True,
        )
        assert completed.returncode == status, completed
        assert completed.stdout == "upgrades false\n", completed

registry = json.loads((root / "tests/suites.json").read_text())
entries = [entry for entry in registry["tests"] if entry.get("suite") == "upgrades"]
assert {entry["path"] for entry in entries} == {
    "tests/test-package-metadata.sh", "tests/test-update-packages.sh",
    "tests/test-update-integrity-failure.sh",
}
with tempfile.TemporaryDirectory() as directory:
    fixture = Path(directory)
    (fixture / "tests").mkdir()
    (fixture / "tests/suites.json").write_text(json.dumps({
        "suites": {"upgrades": registry["suites"]["upgrades"]}, "tests": entries,
    }))
    for entry in entries:
        (fixture / entry["path"]).write_text(
            'if [[ "$FAIL_TEST" == "${0##*/}" ]]; then exit 37; fi\n'
        )
    for failed in entries:
        completed = subprocess.run(
            ["python3", str(root / "scripts/ci/run-tests.py"), "upgrades",
             "--root", str(fixture), "--output", str(fixture / "results")],
            env={**os.environ, "FAIL_TEST": Path(failed["path"]).name},
            capture_output=True, text=True,
        )
        assert completed.returncode != 0, completed
        report = json.loads((fixture / "results/results.json").read_text())
        assert report["status"] == "failure", report
        assert [item["exit_code"] for item in report["results"]] == [
            37 if entry == failed else 0 for entry in entries
        ], report
print("Updater suite and hosted step preserve each test failure")

workflow = contracts.load(Path(sys.argv[1]) / ".github/workflows/arm64-smoke.yml")
for step in workflow["jobs"]["arm64-smoke"]["steps"]:
    if "run" not in step:
        continue
    subprocess.run(["bash", "-n"], input=step["run"], text=True, check=True)
    if step.get("id") == "smoke":
        argv = shlex.split(step["run"])
        subprocess.run(
            ["bash", "-n"], input=argv[argv.index("-c") + 1], text=True, check=True
        )
print("Periodic ARM64 host/container shell syntax passed (no live install)")
PY
