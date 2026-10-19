#!/usr/bin/python3
"""Snapshot stable install destinations and compare successive bootstrap passes."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess


def path_state(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {"type": "absent"}
    value = {"mode": stat.S_IMODE(info.st_mode)}
    # Catch needless command publication even when replacement bytes are equal.
    if stat.S_ISLNK(info.st_mode) or (
        stat.S_ISREG(info.st_mode) and info.st_mode & 0o111
    ):
        value["identity"] = [info.st_dev, info.st_ino]
    if stat.S_ISLNK(info.st_mode):
        value.update(type="symlink", target=os.readlink(path))
    elif stat.S_ISREG(info.st_mode):
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        value.update(type="file", sha256=digest)
    elif stat.S_ISDIR(info.st_mode):
        value["type"] = "directory"
    else:
        value["type"] = "special"
    return value


def tree_state(path):
    result = {str(path): path_state(path)}
    if path.is_dir() and not path.is_symlink():
        for directory, names, files in os.walk(path, followlinks=False):
            for name in sorted(names + files):
                child = Path(directory) / name
                result[str(child)] = path_state(child)
    return result


def ledger_rows(state):
    ledger = state / "installed.tsv"
    rows = []
    if ledger.is_file():
        for line in ledger.read_text().splitlines():
            fields = line.split("\t")
            if len(fields) != 6 or not all(fields):
                raise ValueError(f"Malformed install ledger row: {line!r}")
            rows.append(fields[:5])
    return sorted(rows)


def snapshot(home, state, managed_paths, config_diff):
    rows = ledger_rows(state)
    destinations = {}
    # ChezMoi directories are not recursively scanned: their untracked contents
    # can be caches. Ledger-owned install trees, in contrast, are fully compared.
    for path in managed_paths:
        if not path.is_absolute() or not path.is_relative_to(home):
            raise ValueError(f"Managed destination is outside test home: {path}")
        destinations[str(path)] = path_state(path)
    for row in rows:
        path = Path(row[3])
        if path.is_absolute():
            destinations.update(tree_state(path))
    preserved = {}
    for path in (
        home / ".zsh_history",
        home / ".bash_history",
        home / ".config/dotfiles/local.zsh",
        home / ".config/dotfiles/local.bash",
        home / ".config/dotfiles/local.tmux.conf",
        home / ".config/dotfiles/machine.conf",
        home / ".config/git/config.local",
        home / ".ssh/config.local",
    ):
        preserved.update(tree_state(path))
    replacements = {}
    for directory in ("backups", "binary-backups", "legacy"):
        replacements.update(tree_state(state / directory))
    return {
        "schema": 1,
        "destinations": destinations,
        "ledger": rows,
        "preserved": preserved,
        "config_diff": config_diff,
        "replacements": replacements,
    }


def differences(before, after):
    changes = []
    for key in ("destinations", "preserved", "replacements"):
        for path in sorted(before[key].keys() | after[key].keys()):
            if before[key].get(path) != after[key].get(path):
                changes.append(
                    f"{key}: {path}: {before[key].get(path)} -> {after[key].get(path)}"
                )
    for key in ("ledger", "config_diff"):
        if before[key] != after[key]:
            changes.append(f"{key} changed between installation passes")
    return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("snapshot")
    capture.add_argument("--home", type=Path, default=Path.home())
    capture.add_argument("--state", type=Path, required=True)
    capture.add_argument("--source", type=Path, required=True)
    capture.add_argument("--output", type=Path, required=True)
    compare = commands.add_parser("compare")
    compare.add_argument("before", type=Path)
    compare.add_argument("after", type=Path)
    args = parser.parse_args()
    if args.command == "snapshot":
        base = [
            "chezmoi",
            f"--source={args.source}",
            "--exclude=scripts",
            "--color=false",
        ]
        managed = subprocess.check_output(
            [*base, "managed", "--path-style=absolute"], text=True
        )
        config_diff = subprocess.check_output([*base, "diff"], text=True)
        data = snapshot(
            args.home,
            args.state,
            [Path(line) for line in managed.splitlines()],
            config_diff,
        )
        args.output.write_text(json.dumps(data, sort_keys=True, indent=2) + "\n")
        args.output.chmod(0o600)
    else:
        changes = differences(
            json.loads(args.before.read_text()), json.loads(args.after.read_text())
        )
        if changes:
            raise ValueError(
                "Installation did not converge:\n" + "\n".join(changes[:80])
            )
        print(
            "Installation destinations, ledger, overlays, config diff, and replacements converged"
        )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
