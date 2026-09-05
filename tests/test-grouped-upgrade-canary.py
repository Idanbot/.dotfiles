#!/usr/bin/env python3
"""Credential-free GH contract tests; all dispatches are recorded mocks."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


SHA = "a" * 40
BRANCH = "automation/grouped-tool-upgrades"
URL = "https://github.com/example/dotfiles/actions/runs/123"


def mock_gh():
    args = sys.argv[2:]
    scenario = os.environ["SCENARIO"]
    log = Path(os.environ["MOCK_LOG"])
    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    entry = {"args": args}
    if "--body-file" in args:
        entry["body"] = Path(args[args.index("--body-file") + 1]).read_text()
    with log.open("a") as output:
        output.write(json.dumps(entry) + "\n")
    if args[:2] == ["pr", "list"]:
        result = [] if scenario == "create" else [{"number": 7}]
    elif args[:2] == ["pr", "create"]:
        print("https://github.com/example/dotfiles/pull/7")
        return
    elif args[:2] == ["pr", "edit"]:
        return
    elif args[:2] == ["pr", "comment"]:
        comments = sum(call["args"][:2] == ["pr", "comment"] for call in calls)
        if scenario == "publication-failure" or (scenario == "final-publication-failure" and comments > 0):
            raise SystemExit(37)
        return
    elif args[:2] == ["pr", "view"]:
        views = sum(call["args"][:2] == ["pr", "view"] for call in calls)
        superseded = scenario == "superseded" and views >= 2
        result = {"headRefOid": "b" * 40 if superseded else SHA, "headRefName": BRANCH}
    elif any(arg.endswith("/dispatches") for arg in args):
        assert args[:3] == ["api", "--method", "POST"]
        assert "X-GitHub-Api-Version: 2026-03-10" in args
        assert f"ref={BRANCH}" in args
        assert "inputs[run_heavy_e2e]=true" in args
        if scenario == "dispatch-failure":
            raise SystemExit(37)
        if scenario == "empty-dispatch":
            return
        result = {"workflow_run_id": 123, "html_url": URL}
    elif args[-1].endswith("/jobs?per_page=100"):
        assert "--paginate" in args and "--slurp" in args
        jobs = [{"name": f"Live {profile} E2E", "conclusion": "success"}
                for profile in ("developer", "agent", "cloud", "full")]
        if scenario == "missing-heavy":
            jobs.pop()
        if scenario == "skipped-heavy":
            jobs[0]["conclusion"] = "skipped"
        result = [{"jobs": jobs}]
    elif args == ["api", "repos/example/dotfiles/actions/runs/123"]:
        polls = sum(call["args"] == args for call in calls)
        status = "in_progress" if scenario == "timeout" or (scenario == "refresh" and polls == 0) else "completed"
        if scenario == "approval":
            status = "waiting"
        result = {"id": 123, "head_sha": "b" * 40 if scenario == "wrong-sha" else SHA,
                  "head_branch": BRANCH, "event": "workflow_dispatch", "path": ".github/workflows/ci.yml",
                  "status": status, "conclusion": "failure" if scenario == "failed-canary" else "success"}
        if scenario == "wrong-event":
            result["event"] = "pull_request"
        if scenario == "wrong-workflow":
            result["path"] = ".github/workflows/other.yml"
        if scenario == "poll-failure":
            raise SystemExit(37)
    else:
        raise AssertionError(f"unexpected GH call: {args}")
    print(json.dumps(result))


def test(root):
    scenarios = ("create", "refresh", "no-update", "dispatch-failure", "empty-dispatch",
                 "failed-canary", "wrong-sha", "superseded", "approval", "timeout",
                 "missing-heavy", "skipped-heavy", "wrong-event", "wrong-workflow",
                 "poll-failure", "publication-failure", "final-publication-failure")
    with tempfile.TemporaryDirectory(prefix="canary-contract-") as temp:
        work = Path(temp)
        mock = work / "gh"
        mock.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(Path(__file__).resolve()))} --mock-gh \"$@\"\n")
        mock.chmod(0o755)
        report = work / "upgrades.md"
        report.write_text("Verified fixture updates\n")
        for scenario in scenarios:
            output = work / scenario
            log = work / f"{scenario}.jsonl"
            result = subprocess.run(
                [sys.executable, str(root / "scripts/grouped-upgrade-canary.py"),
                 "--changed", "false" if scenario == "no-update" else "true", "--sha", SHA,
                 "--report", str(report), "--output", str(output), "--poll-interval", "0",
                 "--timeout", "0" if scenario == "timeout" else "5"],
                env={"PATH": f"{work}:/usr/bin:/bin", "GITHUB_REPOSITORY": "example/dotfiles",
                     "MOCK_LOG": str(log), "SCENARIO": scenario, "HOME": str(work)},
                text=True, capture_output=True, timeout=15,
            )
            outcome = json.loads((output / "canary.json").read_text())
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            success = scenario in ("create", "refresh", "no-update")
            assert (result.returncode == 0) == success, (scenario, result.stdout, result.stderr)
            assert outcome["outcome"] == ("no-update" if scenario == "no-update" else "success" if success else "failure"), outcome
            if scenario == "no-update":
                assert not calls, "unchanged source must not call GH"
            else:
                dispatches = [call for call in calls if any(arg.endswith("/dispatches") for arg in call["args"])]
                assert len(dispatches) == 1
                assert sum(call["args"][:2] == ["pr", "create"] for call in calls) == (scenario == "create")
                assert sum(call["args"][:2] == ["pr", "edit"] for call in calls) == (scenario != "create")
                comments = [call["body"] for call in calls if call["args"][:2] == ["pr", "comment"]]
                assert comments and SHA in comments[-1]
                if scenario not in ("dispatch-failure", "empty-dispatch"):
                    assert outcome["runUrl"] == URL and URL in comments[-1]
                if scenario not in ("publication-failure", "final-publication-failure"):
                    assert f"**{outcome['outcome']}**" in comments[-1]
                assert f"**{outcome['outcome']}**" in (output / "canary.md").read_text()
                assert not any("/actions/runs?" in arg for call in calls for arg in call["args"])
            print(f"[PASS] grouped canary: {scenario}")


if __name__ == "__main__":
    if sys.argv[1] == "--mock-gh":
        mock_gh()
    else:
        test(Path(sys.argv[1]).resolve())
