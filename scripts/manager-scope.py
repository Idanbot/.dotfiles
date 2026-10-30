#!/usr/bin/python3
"""Resolve one package's payload and command bindings without executing it."""

import argparse
from email.parser import Parser
import json
from pathlib import Path
import re
import sys
import tomllib


def canonical(path):
    if not path.is_absolute() or path.resolve() != path:
        raise ValueError("redirected or noncanonical manager path")
    return path


def command_name(value):
    if not isinstance(value, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._+-]*", value
    ):
        raise ValueError("invalid command name")
    return value


def normalize(value):
    return re.sub(r"[-_.]+", "-", value).lower()


def scope(kind, root, bins, package, binary, links_only=False):
    canonical(root)
    canonical(bins)
    home = Path.home()
    if not root.is_relative_to(home) or root in {home, home / ".local", bins}:
        raise ValueError("manager root is outside its private package scope")
    pattern = r"@[a-z0-9_.-]+/[a-z0-9_.-]+|[A-Za-z0-9][A-Za-z0-9._+-]*"
    if not re.fullmatch(pattern, package) or ".." in package.split("/"):
        raise ValueError("invalid package identity")
    target = (
        root / package
        if kind in {"uv", "python"}
        else root / "lib/node_modules" / package
    )
    if kind == "omp":
        if root != home / ".omp/plugins":
            raise ValueError("OMP removal requires its native global plugin root")
        target = root / "node_modules" / package
    canonical(target)
    if links_only:
        links = (
            sorted(
                path
                for path in bins.iterdir()
                if path.is_symlink() and path.resolve().is_relative_to(target)
            )
            if bins.exists()
            else []
        )
        return "", target, links
    entries = {}
    version = ""
    if target.exists():
        if kind == "uv":
            data = tomllib.loads(canonical(target / "uv-receipt.toml").read_text())[
                "tool"
            ]
            requirement = data["requirements"][0]
            name = (
                requirement["name"]
                if isinstance(requirement, dict)
                else requirement.split("==")[0]
            )
            if normalize(name) != normalize(package):
                raise ValueError("uv receipt identifies a different package")
            for entry in data["entrypoints"]:
                name = command_name(entry["name"])
                if Path(entry["install-path"]) != bins / name:
                    raise ValueError(
                        "uv entrypoint is outside the executable directory"
                    )
                entries[name] = target / "bin" / name
            for metadata in target.glob(
                "lib/python*/site-packages/*.dist-info/METADATA"
            ):
                record = Parser().parsestr(metadata.read_text())
                if normalize(record.get("Name", "")) == normalize(package):
                    version = record["Version"]
                    break
        elif kind in {"npm", "omp"}:
            data = json.loads(canonical(target / "package.json").read_text())
            if data["name"] != package:
                raise ValueError("package manifest identifies a different package")
            version = str(data["version"])
            if kind == "npm":
                declarations = data.get("bin", {})
                if isinstance(declarations, str):
                    declarations = {package.split("/")[-1]: declarations}
                for name, relative in declarations.items():
                    command_name(name)
                    payload = (target / relative).resolve()
                    if not payload.is_relative_to(target):
                        raise ValueError("package command escapes its payload")
                    entries[name] = payload
        elif kind == "python":
            if not re.fullmatch(
                r"cpython-\d+(?:\.\d+){2}[-+][A-Za-z0-9._+-]+", package
            ):
                raise ValueError(
                    "Python removal requires an exact managed installation key"
                )
    if kind == "python" and not target.is_dir():
        raise ValueError("Python installation is absent or unverifiable")
    paths = set()
    if kind == "python" and bins.exists():
        paths.update(
            path
            for path in bins.iterdir()
            if path.is_symlink() and path.resolve().is_relative_to(target)
        )
    for name, payload in entries.items():
        link = bins / name
        if (
            not link.is_symlink()
            or link.resolve() != payload.resolve()
            or not payload.is_file()
        ):
            raise ValueError("manager command no longer binds to its package")
        paths.add(link)
    if kind in {"npm", "uv"} and binary:
        command_name(binary)
        if target.exists() and binary not in entries:
            raise ValueError("requested command is absent from the package receipt")
        if not target.exists() and (
            (bins / binary).exists() or (bins / binary).is_symlink()
        ):
            raise ValueError("command exists without a verifiable package payload")
        paths.add(bins / binary)
        if kind == "npm":
            published = home / ".local/bin" / binary
            canonical(published.parent)
            if published.exists() or published.is_symlink():
                if (
                    binary not in entries
                    or not published.is_symlink()
                    or published.resolve() != entries[binary].resolve()
                ):
                    raise ValueError("published command no longer binds to the package")
            paths.add(published)
    return version, target, sorted(paths)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("npm", "uv", "omp", "python"))
    parser.add_argument("root", type=Path)
    parser.add_argument("bins", type=Path)
    parser.add_argument("package")
    parser.add_argument("binary", nargs="?", default="")
    parser.add_argument("--links-only", action="store_true")
    args = parser.parse_args()
    version, target, paths = scope(
        args.kind, args.root, args.bins, args.package, args.binary, args.links_only
    )
    for value in [version, str(target), *(str(path) for path in paths)]:
        if any(ord(char) < 32 for char in value):
            raise ValueError("control characters in manager metadata")
        print(value)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, IndexError, AttributeError):
        sys.exit(
            "Package-manager scope is invalid or unverifiable; existing files were preserved"
        )
