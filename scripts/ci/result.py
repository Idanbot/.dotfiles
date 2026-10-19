#!/usr/bin/env python3
"""Fail closed on missing, failed, cancelled, or unexpectedly skipped jobs."""

import argparse
import json
import os


def failures(needs, optional=()):
    return [
        f"{name}: {job.get('result', 'missing')}"
        for name, job in needs.items()
        if job.get("result") != "success"
        and not (name in optional and job.get("result") == "skipped")
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--required", nargs="+", required=True)
    parser.add_argument("--optional", nargs="*", default=[])
    args = parser.parse_args()
    needs = json.loads(os.environ["CI_NEEDS"])
    errors = failures(needs, args.optional)
    errors.extend(f"{name}: missing" for name in args.required if name not in needs)
    if errors:
        raise SystemExit("CI failed: " + "; ".join(errors))
    print("All required CI jobs succeeded")


if __name__ == "__main__":
    main()
