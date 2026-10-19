#!/usr/bin/env python3
"""Semantic contracts for the CI graph and its security boundaries."""

import argparse
from pathlib import Path

import yaml


def load(path):
    return yaml.safe_load(path.read_text())


def triggers(workflow):
    return workflow.get("on", workflow.get(True, {}))


def needs(job):
    value = job.get("needs", [])
    return {value} if isinstance(value, str) else set(value)


def check(root):
    workflows = {
        path.name: load(path) for path in (root / ".github/workflows").glob("*.yml")
    }
    main = workflows["ci.yml"]
    reusable = [
        name for name, wf in workflows.items() if "workflow_call" in triggers(wf)
    ]
    assert set(reusable) == {"ci-checks.yml", "ci-live.yml"}, reusable
    assert set(main["jobs"]) == {"checks", "live", "result"}
    assert main["jobs"]["checks"]["uses"].endswith("/ci-checks.yml")
    assert main["jobs"]["live"]["uses"].endswith("/ci-live.yml")
    assert needs(main["jobs"]["live"]) == {"checks"}
    final = main["jobs"]["result"]
    assert final["name"] == "CI Result" and final["if"] == "always()"
    assert needs(final) == set(main["jobs"]) - {"result"}
    final_run = "\n".join(step.get("run", "") for step in final["steps"])
    assert "--required checks live" in final_run
    concurrency = main["concurrency"]
    assert "github.run_id" in concurrency["group"]
    assert "workflow_dispatch" in concurrency["group"]
    assert "push" in concurrency["cancel-in-progress"]
    assert "pull_request" in concurrency["cancel-in-progress"]
    heavy = main["jobs"]["live"]["with"]["heavy"]
    assert all(
        key in heavy
        for key in ("schedule", "run_heavy_e2e", "automation/grouped-tool-upgrades")
    )

    checks = workflows["ci-checks.yml"]["jobs"]
    for name in ("gitleaks", "hadolint", "trivy", "dependency-review", "test-image"):
        assert not needs(checks[name]), f"{name} must start without a live dependency"
    assert needs(checks["contracts"]) == {"test-image"}
    matrix = checks["contracts"]["strategy"]["matrix"]["include"]
    suites = {entry["suite"] for entry in matrix}
    assert suites == {
        "static",
        "behavior",
        "selectors",
        "workspace",
        "benchmarks",
        "workflow-security",
    }
    assert {
        (entry["platform"], entry["wsl"])
        for entry in matrix
        if entry["suite"] == "behavior"
    } == {("native", "false"), ("wsl-simulated", "true")}
    suite_step = next(
        step
        for step in checks["contracts"]["steps"]
        if "CI_SUITE" in step.get("env", {})
    )
    assert suite_step["env"]["DOTFILES_WSL"] == "${{ matrix.wsl }}"
    upload = next(
        step
        for step in checks["contracts"]["steps"]
        if "upload-artifact@" in step.get("uses", "")
    )
    assert "matrix.platform" in upload["with"]["name"]
    image_steps = checks["test-image"]["steps"]
    image_upload = next(
        step for step in image_steps if "upload-artifact@" in step.get("uses", "")
    )
    assert image_upload["with"]["retention-days"] == 1
    assert "github.sha" in image_upload["with"]["name"]
    assert any(
        step.get("env", {}).get("DOTFILES_CI_SKIP_BUILD") == "true"
        for step in checks["contracts"]["steps"]
    )

    live = workflows["ci-live.yml"]["jobs"]
    assert needs(live["github-release-tools"]) == {"version-report"}
    for name in ("base-e2e", "recovery-e2e"):
        assert needs(live[name]) == {"github-release-tools"}
    assert needs(live["heavy-e2e"]) == {"base-e2e", "recovery-e2e"}
    assert live["heavy-e2e"]["if"] == "inputs.heavy"
    assert live["heavy-e2e"]["name"] == "Live ${{ matrix.service }} E2E"
    assert {"full", "full-native"} <= set(
        live["heavy-e2e"]["strategy"]["matrix"]["service"]
    )
    assert live["result"]["if"] == "always()"
    assert needs(live["result"]) == set(live) - {"result"}
    services = load(root / ".github/e2e/compose.yaml")["services"]
    for name in ("base-native", "base-wsl-simulated", "full", "full-native"):
        assert services[name]["environment"]["E2E_PASSES"] == "2"
        assert services[name]["build"]["target"] == "base"
    assert services["full-native"]["environment"]["DOTFILES_WSL"] == "false"
    assert services["full"]["environment"]["DOTFILES_WSL"] == "true"

    outcome = workflows["ci-outcome.yml"]["jobs"]["classify"]
    assert outcome["if"] == "github.event.workflow_run.conclusion != 'success'"
    checkout = next(
        step for step in outcome["steps"] if "checkout@" in step.get("uses", "")
    )
    assert checkout["with"]["ref"] == "${{ github.event.repository.default_branch }}"
    assert outcome["permissions"] == {
        "actions": "read",
        "checks": "write",
        "contents": "read",
    }

    daily = workflows["vulnerability-audit.yml"]
    weekly = workflows["version-audit.yml"]
    assert triggers(daily)["schedule"] == [{"cron": "23 4 * * 0,2-6"}]
    assert triggers(weekly)["schedule"] == [{"cron": "17 4 * * 1"}]
    for workflow, mode in ((daily, "daily"), (weekly, "weekly")):
        assert "workflow_dispatch" in triggers(workflow)
        commands = "\n".join(
            step.get("run", "")
            for job in workflow["jobs"].values()
            for step in job["steps"]
        )
        assert f"scripts/ci/maintenance-audit.sh {mode}" in commands
        assert "requirements-audit.txt" in commands
    assert daily["permissions"] == {"contents": "read"}
    assert weekly["jobs"]["report"]["permissions"] == {
        "contents": "read",
        "issues": "write",
    }
    grouped = workflows["grouped-upgrades.yml"]
    assert triggers(grouped)["schedule"] == [{"cron": "17 4 1 * *"}]
    assert grouped["jobs"]["update"]["permissions"] == {
        "contents": "write",
        "pull-requests": "write",
        "actions": "write",
    }
    canary_steps = [
        step
        for step in grouped["jobs"]["update"]["steps"]
        if "scripts/grouped-upgrade-canary.py" in step.get("run", "")
    ]
    assert len(canary_steps) == 1
    assert canary_steps[0]["if"] == "steps.upgrades.outputs.changed == 'true'"
    assert "--changed true" in canary_steps[0]["run"]
    assert "schedule" in triggers(workflows["native-vm-e2e.yml"])
    assert set(triggers(workflows["wsl-e2e.yml"])) == {"workflow_dispatch"}

    for filename, workflow in workflows.items():
        assert "permissions" in workflow, f"{filename}: implicit token permissions"
        for name, job in workflow["jobs"].items():
            if "uses" not in job:
                assert 0 < job.get("timeout-minutes", 0) <= 240, (filename, name)
            for step in job.get("steps", []):
                if "checkout@" in step.get("uses", ""):
                    assert step.get("with", {}).get("persist-credentials") is False
                command = step.get("run", "")
                assert not any(
                    term in command
                    for term in ("gh run delete", "gh api --method DELETE")
                )
    return workflows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "root", nargs="?", type=Path, default=Path(__file__).resolve().parents[2]
    )
    args = parser.parse_args()
    check(args.root)
    print("CI graph, maintenance, acceptance, and token contracts passed")


if __name__ == "__main__":
    main()
