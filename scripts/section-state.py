#!/usr/bin/env python3
"""Canonical section inputs for bootstrap and targeted reconciliation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import yaml


def registry(root):
    return json.loads((root / "scripts/sections.json").read_text())


def fingerprint(root, name):
    entry = registry(root)[name]
    inputs = {"schema": 1, "section": name, "definition": entry}
    for filename in ("packages.yaml", "packages.meta.yaml"):
        data = yaml.safe_load((root / filename).read_text()) or {}
        for excluded in entry.get("exclude", []):
            group, key = excluded.split(".", 1)
            data.get(group, {}).pop(key, None)
        selected = {}
        for key in entry["manifest"]:
            value = data
            for part in key.split("."):
                value = value.get(part) if isinstance(value, dict) else None
            selected[key] = value
        inputs[filename] = selected
    for filename in [entry["script"], "scripts/lib.sh", "scripts/environment.sh",
                     "scripts/section-state.py", *entry.get("files", [])]:
        path = root / filename
        inputs[filename] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    return hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def record(root, state, name):
    directory = state / "package-sections"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(fingerprint(root, name) + "\n")
        os.replace(temporary, directory / f"{name}.sha256")
    finally:
        Path(temporary).unlink(missing_ok=True)


def selected_sections(state):
    selected = state / "selected-sections"
    if selected.is_file():
        return selected.read_text().strip()
    summaries = sorted((state / "runs").glob("*/summary.json"),
                       key=lambda path: path.stat().st_mtime, reverse=True)
    for path in summaries:
        summary = json.loads(path.read_text())
        if summary.get("status") == "success":
            return summary["sections"]
    raise ValueError("No installed selection recorded; run bootstrap or specify --sections explicitly")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--state", type=Path)
    parser.add_argument("command", choices=["list", "script", "fingerprint", "record", "selected"])
    parser.add_argument("section", nargs="?")
    args = parser.parse_args()
    entries = registry(args.source)
    if args.command == "list":
        print("\n".join(entries))
    elif args.command == "selected":
        print(selected_sections(args.state))
    elif args.section not in entries:
        parser.error(f"Unknown section: {args.section}")
    elif args.command == "script":
        print(entries[args.section]["script"])
    elif args.command == "fingerprint":
        print(fingerprint(args.source, args.section))
    else:
        record(args.source, args.state, args.section)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit(str(error)) from error
