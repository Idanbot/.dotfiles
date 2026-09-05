#!/usr/bin/env python3
"""Publish one grouped PR and await the exact explicitly dispatched canary."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


BRANCH = "automation/grouped-tool-upgrades"
WORKFLOW = "ci.yml"
HEAVY_JOBS = {f"Live {profile} E2E" for profile in ("developer", "agent", "cloud", "full")}


def gh(*args):
    result = subprocess.run(["gh", *args], text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f"gh {' '.join(args[:2])} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def gh_json(*args):
    return json.loads(gh(*args))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changed", choices=("true", "false"), required=True)
    parser.add_argument("--sha")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=10800)
    parser.add_argument("--poll-interval", type=float, default=30)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    outcome = {"outcome": "no-update", "headSha": args.sha, "runUrl": None, "runId": None}
    pr = None
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    api = f"repos/{repo}"

    def publish(body):
        with tempfile.TemporaryDirectory(prefix="grouped-canary-") as temp:
            body_file = Path(temp) / "body.md"
            body_file.write_text(body)
            gh("pr", "comment", str(pr), "--repo", repo, "--body-file", str(body_file))

    def verify_head():
        current = gh_json("pr", "view", str(pr), "--repo", repo, "--json", "headRefOid,headRefName")
        if current["headRefOid"] != args.sha or current["headRefName"] != BRANCH:
            raise RuntimeError("superseded: grouped PR no longer points to the requested commit/branch")

    try:
        if args.changed == "false":
            return 0
        outcome["outcome"] = "failure"
        if not repo or not args.sha or not args.report:
            raise ValueError("changed updates require GITHUB_REPOSITORY, --sha and --report")
        body = (
            "This monthly PR aggregates every fully verified tool update into one review.\n\n"
            "The heavy canary is explicitly dispatched and tracked in PR comments. "
            "Token-created PR event runs may separately require approval.\n\n"
            + args.report.read_text()
        )
        prs = gh_json("pr", "list", "--repo", repo, "--state", "open", "--base", "main",
                      "--head", BRANCH, "--json", "number")
        if len(prs) > 1:
            raise RuntimeError("multiple open grouped PRs; refusing ambiguous update")
        with tempfile.TemporaryDirectory(prefix="grouped-pr-") as temp:
            body_file = Path(temp) / "body.md"
            body_file.write_text(body)
            common = ("--repo", repo, "--title", "chore: grouped monthly tool upgrades", "--body-file", str(body_file))
            if prs:
                pr = prs[0]["number"]
                gh("pr", "edit", str(pr), *common)
            else:
                pr = gh("pr", "create", "--base", "main", "--head", BRANCH, *common)
        outcome["pr"] = pr
        verify_head()
        # API 2026-03-10 returns the dispatched run ID directly. Fail closed on
        # an empty/legacy response; never guess from a recent green run list.
        dispatch = gh_json(
            "api", "--method", "POST", f"{api}/actions/workflows/{WORKFLOW}/dispatches",
            "-H", "X-GitHub-Api-Version: 2026-03-10", "-f", f"ref={BRANCH}",
            "-F", "inputs[run_heavy_e2e]=true",
        )
        run_id = dispatch["workflow_run_id"]
        if type(run_id) is not int or run_id <= 0:
            raise RuntimeError("dispatch returned an invalid run ID")
        run_url = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{repo}/actions/runs/{run_id}"
        if dispatch["html_url"] != run_url:
            raise RuntimeError("dispatch returned an unexpected run URL")
        outcome.update(runId=run_id, runUrl=run_url)
        publish(f"Grouped upgrade canary for `{args.sha}`: [run]({run_url}) is pending.\n\n"
                "Dispatched with `run_heavy_e2e=true`; success is not yet verified.")
        deadline = time.monotonic() + args.timeout
        while True:
            verify_head()
            run = gh_json("api", f"{api}/actions/runs/{run_id}")
            if (run["id"] != run_id or run["head_sha"] != args.sha
                    or run["head_branch"] != BRANCH or run["event"] != "workflow_dispatch"
                    or run["path"] != ".github/workflows/ci.yml"):
                raise RuntimeError("correlation mismatch: run ID/headSha/branch/event/workflow does not match dispatch")
            outcome.update(status=run["status"], conclusion=run["conclusion"])
            if run["status"] == "completed":
                if run["conclusion"] != "success":
                    raise RuntimeError(f"canary concluded {run['conclusion']}")
                pages = gh_json("api", "--paginate", "--slurp", f"{api}/actions/runs/{run_id}/jobs?per_page=100")
                jobs = [job for page in pages for job in page["jobs"] if job["name"] in HEAVY_JOBS]
                if ({job["name"] for job in jobs} != HEAVY_JOBS or len(jobs) != 4
                        or any(job["conclusion"] != "success" for job in jobs)):
                    raise RuntimeError("heavy matrix missing, skipped, or unsuccessful")
                verify_head()
                outcome["outcome"] = "success"
                return 0
            if run["status"] in ("waiting", "action_required", "pending"):
                raise RuntimeError(f"canary pending approval or intervention: {run['status']}")
            if time.monotonic() >= deadline:
                raise RuntimeError(f"timed out awaiting canary: {run['status']}; approval may be required")
            time.sleep(args.poll_interval)
    except (RuntimeError, ValueError, KeyError, OSError, subprocess.TimeoutExpired) as error:
        outcome.update(outcome="failure", detail=str(error))
        return 1
    finally:
        summary = (
            f"Grouped upgrade canary: **{outcome['outcome']}**\n\n"
            f"Commit: `{args.sha or 'unchanged'}`\n\n"
            + (f"Run: [canary]({outcome['runUrl']})\n\n" if outcome["runUrl"] else "Run: not established.\n\n")
            + outcome.get("detail", "") + "\n"
        )
        if pr:
            try:
                publish(summary)
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                outcome.update(outcome="failure", publicationError=str(error))
                summary = summary.replace("**success**", "**failure**", 1)
                summary += f"\nPR publication failed: {error}\n"
        (args.output / "canary.json").write_text(json.dumps(outcome, indent=2) + "\n")
        (args.output / "canary.md").write_text(summary)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as step_summary:
                step_summary.write(summary)
        print(summary)
        # A green canary without a published PR outcome is not completion.
        if outcome.get("publicationError"):
            raise SystemExit(1)


if __name__ == "__main__":
    raise SystemExit(main())
