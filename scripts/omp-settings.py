#!/usr/bin/python3
"""Prepare native OMP/Pix settings without replacing user choices."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import tempfile


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate-json-key")
        result[key] = value
    return result


def read_object(path):
    if path.parent.resolve() != path.parent or path.is_symlink():
        raise ValueError("redirected-settings")
    if not path.exists():
        return {}
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("nonregular-settings")
        content = stream.read(1024 * 1024 + 1)
    if len(content) > 1024 * 1024:
        raise ValueError("settings-too-large")
    data = json.loads(content, object_pairs_hook=object_pairs)
    if not isinstance(data, dict):
        raise ValueError("settings-not-object")
    return data


def prepare(path, mode, overrides=None, legacy=None):
    path = path.expanduser().absolute()
    data = read_object(path)
    original = json.dumps(data, sort_keys=True)
    if mode == "plugins":
        if not isinstance(overrides, dict) or not overrides:
            raise ValueError("invalid-overrides")
        for name, version in overrides.items():
            if not re.fullmatch(r"@[a-z0-9-]+/[a-z0-9-]+", name) or not (
                isinstance(version, str) and re.fullmatch(r"\d+\.\d+\.\d+", version)
            ):
                raise ValueError("invalid-override")
        existing = data.setdefault("overrides", {})
        if not isinstance(existing, dict):
            raise ValueError("overrides-not-object")
        if any(
            name in existing and existing[name] != version
            for name, version in overrides.items()
        ):
            raise ValueError("conflicting-user-override-review-package-json")
        existing.update(overrides)
        data.setdefault("private", True)
    else:
        optimizer = data.setdefault("optimizer", {})
        if not isinstance(optimizer, dict):
            raise ValueError("optimizer-not-object")
        if any(key not in optimizer for key in ("caveman", "rtk", "ponytail")):
            previous = read_object(legacy.expanduser().absolute()) if legacy else {}
            allowed = {
                "caveman": {"off", "lite", "full", "ultra", "micro"},
                "rtk": {"off", "on"},
                "ponytail": {"off", "lite", "full", "ultra"},
            }
            for key, values in allowed.items():
                if key not in optimizer:
                    value = previous.get(key, "off")
                    if not isinstance(value, str) or value not in values:
                        raise ValueError("invalid-legacy-choice")
                    optimizer[key] = value
    if json.dumps(data, sort_keys=True) == original:
        return False
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".omp-settings-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
        if path.parent.resolve() != path.parent or path.is_symlink():
            raise ValueError("redirected-settings")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("plugins", "optimizer"))
    parser.add_argument("path", type=Path)
    parser.add_argument("--overrides")
    parser.add_argument("--legacy", type=Path)
    args = parser.parse_args()
    try:
        changed = prepare(
            args.path,
            args.mode,
            json.loads(args.overrides, object_pairs_hook=object_pairs)
            if args.overrides
            else None,
            args.legacy,
        )
    except (OSError, ValueError):
        parser.exit(
            1,
            "omp-settings: unsafe, invalid, or conflicting settings; preserved for manual review\n",
        )
    print("changed" if changed else "unchanged")


if __name__ == "__main__":
    main()
