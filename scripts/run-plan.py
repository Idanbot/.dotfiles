#!/usr/bin/env python3
"""Persist and validate the immutable inputs of a resumable bootstrap run."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile


def source_digest(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if any(part in {".git", ".github", "docs", "tests", "__pycache__", "artifacts"}
               for part in relative.parts):
            continue
        if path.is_symlink():
            payload = os.readlink(path).encode()
        elif path.is_file():
            payload = path.read_bytes()
        else:
            continue
        digest.update(str(relative).encode() + b"\0" + hashlib.sha256(payload).digest())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "options"])
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--sections")
    parser.add_argument("--profile")
    parser.add_argument("--conflict-policy")
    parser.add_argument("--doctor")
    parser.add_argument("--only", default="")
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    destination = args.run_dir / "plan.json"
    if args.command == "options":
        data = json.loads(destination.read_text())
        for key in ("conflict_policy", "doctor", "only"):
            print(f"{key}\t{data[key]}")
        return
    data = {"schema": 1, "source": str(args.source.resolve()),
            "source_sha256": source_digest(args.source), "sections": args.sections,
            "profile": args.profile, "conflict_policy": args.conflict_policy,
            "doctor": args.doctor, "only": args.only}
    if args.resume:
        if not destination.is_file():
            raise ValueError("Legacy run has no validated plan. Start a new bootstrap run; existing backups are preserved.")
        original = json.loads(destination.read_text())
        changed = [key for key, value in data.items() if original.get(key) != value]
        if changed:
            raise ValueError("Resume inputs changed (" + ", ".join(changed) +
                             "). Start a new bootstrap run to re-plan and review conflicts; no checkpoint was replayed.")
        return
    descriptor, temporary = tempfile.mkstemp(dir=args.run_dir)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit(str(error)) from error
