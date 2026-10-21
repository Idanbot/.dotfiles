#!/usr/bin/env python3
"""Content-addressed, weekly refreshed CI caches; never include home/config state."""

import argparse
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import re

VALIDATOR_INPUTS = (
    ".github/e2e/Dockerfile.ubuntu-24.04",
    ".github/e2e/requirements-validators.txt",
    "requirements-audit.txt",
    "scripts/ci/validator-image.sh",
    "scripts/ci/cache-policy.py",
)


def cache_key(root, platform, today):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", platform):
        raise ValueError("Invalid cache platform")
    period = today.strftime("%G-W%V")
    digest = hashlib.sha256()
    for relative in VALIDATOR_INPUTS:
        payload = (root / relative).read_bytes()
        digest.update(relative.encode() + b"\0" + payload + b"\0")
    return f"validators-v1-{platform}-{period}-{digest.hexdigest()}", period


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[2]
    )
    parser.add_argument("--platform", required=True)
    args = parser.parse_args()
    key, period = cache_key(args.root, args.platform, datetime.now(timezone.utc))
    print(f"key={key}\nperiod={period}")


if __name__ == "__main__":
    main()
