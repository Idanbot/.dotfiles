#!/usr/bin/python3
"""Canonical section inputs for bootstrap and targeted reconciliation."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import yaml

# Keep the registry reader stdlib-only so standalone generation needs no PyYAML.
_spec = importlib.util.spec_from_file_location("section_registry", Path(__file__).with_name("section-registry.py"))
_registry = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_registry)


def registry(root):
    return _registry.registry(root)


def fingerprint(root, name):
    entry = registry(root)[name]
    inputs = {"schema": 2, "section": name, "definition": entry}
    if entry.get("externals"):
        inputs["externals"] = external_entries(root, name)
        helper = root / "scripts/reconcile-externals.sh"
        inputs["external_helper"] = hashlib.sha256(helper.read_bytes()).hexdigest() if helper.is_file() else None
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
    # Policies are data, not global helpers: only the owning manifest slice counts.
    policies = json.loads((root / "scripts/update-policy.json").read_text()) if (root / "scripts/update-policy.json").is_file() else {}
    inputs["policies"] = {key: value for key, value in policies.items()
                          if key not in entry.get("exclude", []) and any(
                              key == prefix or key.startswith(prefix + ".") for prefix in entry["manifest"])}
    filenames = {entry["script"], "scripts/section-state.py", "scripts/section-registry.py", *entry.get("files", [])}
    for pattern in entry["shared_inputs"]:
        matches = list(root.glob(pattern))
        filenames.update(str(path.relative_to(root)) for path in matches if path.is_file())
        if not any(character in pattern for character in "*?["):
            filenames.add(pattern)
    for filename in sorted(filenames):
        path = root / filename
        inputs[filename] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    return hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def external_entries(root, name):
    prefixes = registry(root)[name].get("externals", [])
    if not prefixes:
        return {}
    entries = yaml.safe_load((root / ".chezmoiexternal.yaml").read_text()) or {}
    return {path: value for path, value in entries.items()
            if any(path == prefix or path.startswith(prefix + "/") for prefix in prefixes)}


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
    parser.add_argument("command", choices=["list", "script", "fingerprint", "record", "selected", "externals", "describe", "commands"])
    parser.add_argument("section", nargs="?")
    args = parser.parse_args()
    entries = registry(args.source)
    if args.command == "list":
        print("\n".join(entries))
    elif args.command == "describe":
        for name, entry in entries.items():
            print(f"  {name:12s} {entry['description']}")
    elif args.command == "selected":
        print(selected_sections(args.state))
    elif args.section not in entries:
        parser.error(f"Unknown section: {args.section}")
    elif args.command == "script":
        print(entries[args.section]["script"])
    elif args.command == "commands":
        entry = entries[args.section]
        for field, kind in (("commands", "required"), ("optional_commands", "optional"), ("stable_commands", "stable")):
            for command in entry.get(field, []):
                print(f"{kind}\t{command}\t{'native' if entry.get('native_only') else 'all'}")
    elif args.command == "externals":
        for path in external_entries(args.source, args.section):
            print(path)
    elif args.command == "fingerprint":
        print(fingerprint(args.source, args.section))
    else:
        record(args.source, args.state, args.section)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit(str(error)) from error
