#!/usr/bin/python3
"""Refresh one standing upgrade-advisory issue without per-tool issues or comments."""
import argparse
import json
import os
from pathlib import Path
import subprocess

TITLE = "Latest stable upgrade recommendations"


def publish(report, repo):
    def gh(*args):
        result = subprocess.run(["gh", *args, "--repo", repo],
                                capture_output=True, text=True, timeout=60, check=True)
        return result.stdout
    issues = json.loads(gh("issue", "list", "--state", "open", "--limit", "100",
                          "--search", f'"{TITLE}" in:title', "--json", "number,title"))
    matches = [issue for issue in issues if issue["title"] == TITLE]
    if len(matches) > 1:
        raise ValueError("Multiple upgrade advisory issues; refusing an ambiguous update")
    if matches:
        return gh("issue", "edit", str(matches[0]["number"]), "--body-file", str(report))
    return gh("issue", "create", "--title", TITLE, "--body-file", str(report))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    print(publish(args.report, os.environ["GITHUB_REPOSITORY"]))
