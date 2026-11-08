#!/usr/bin/python3
"""Remove the retired bootstrap Pix compatibility override, preserving user settings."""

import argparse
import json
import os
from pathlib import Path
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


def prepare(path):
    path = path.expanduser().absolute()
    data = read_object(path)
    original = json.dumps(data, sort_keys=True)
    existing = data.get("overrides", {})
    if not isinstance(existing, dict):
        raise ValueError("overrides-not-object")
    if existing.get("@xynogen/pix-pretty") == "1.30.0":
        del existing["@xynogen/pix-pretty"]
        if not existing:
            data.pop("overrides", None)
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
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        changed = prepare(args.path)
    except (OSError, ValueError):
        parser.exit(
            1,
            "omp-settings: unsafe, invalid, or conflicting settings; preserved for manual review\n",
        )
    print("changed" if changed else "unchanged")


if __name__ == "__main__":
    main()
