#!/usr/bin/python3
"""Apply a reviewed upgrade plan using YAML node positions, preserving comments."""

import argparse
import json
import os
from pathlib import Path
import re
import tempfile

import yaml

from dotfiles.metadata import load_metadata, load_versions


def scalar_node(document, keys):
    node = yaml.compose(document, Loader=yaml.BaseLoader)
    for key in keys:
        if not isinstance(node, yaml.MappingNode):
            raise ValueError(f"Expected mapping before {'.'.join(keys)}")
        matches = [value for name, value in node.value if name.value == key]
        if len(matches) != 1:
            raise ValueError(f"Missing or duplicate YAML key: {'.'.join(keys)}")
        node = matches[0]
    if not isinstance(node, yaml.ScalarNode):
        raise ValueError(f"Expected scalar at {'.'.join(keys)}")
    return node


def render_edits(document, changes):
    edits = []
    for keys, value, quote in changes:
        node = scalar_node(document, keys)
        replacement = json.dumps(value) if quote or node.style else value
        edits.append((node.start_mark.index, node.end_mark.index, replacement))
    edits.sort(reverse=True)
    previous = len(document) + 1
    for start, end, replacement in edits:
        if end >= previous:
            raise ValueError("Overlapping YAML updates or shared scalar aliases")
        document = document[:start] + replacement + document[end:]
        previous = start
    yaml.safe_load(document)
    return document


def digest(value):
    if not re.fullmatch(r"[0-9a-fA-F]{64}", value):
        raise ValueError("Invalid SHA256 in accepted upgrade plan")
    return value.lower()


def apply(packages_path, metadata_path, externals_path, plan_path):
    versions = load_versions(packages_path)
    load_metadata(metadata_path)
    paths = (packages_path, metadata_path, externals_path)
    documents = [path.read_text() for path in paths]
    changes = [[], [], []]
    seen = set()
    for raw in plan_path.read_text().splitlines():
        ident, section, key, current, latest, integrity, delta = raw.split("\t", 6)
        if ident != f"{section}.{key}" or ident in seen:
            raise ValueError("Invalid or duplicate upgrade target")
        seen.add(ident)
        if versions.get(section, {}).get(key) != current:
            raise ValueError(f"Manifest changed since planning: {ident}")
        changes[0].append(((section, key), latest, True))
        if ident == "core.fzf":
            checksum = digest(delta.split(" -> ", 1)[1].removeprefix("sha256:"))
            changes[2].extend(
                [
                    (
                        (".fzf", "url"),
                        f"https://codeload.github.com/junegunn/fzf/tar.gz/refs/tags/v{latest}",
                        True,
                    ),
                    ((".fzf", "checksum", "sha256"), checksum, True),
                ]
            )
        elif integrity == "pinned-sha256":
            values = dict(
                part.split(":", 1) for part in delta.split(" -> ", 1)[1].split(";")
            )
            if "sha256" in values:
                changes[1].append(
                    ((section, key, "sha256"), digest(values["sha256"]), False)
                )
            else:
                for arch in ("amd64", "arm64"):
                    changes[1].append(
                        (
                            (section, key, f"sha256_{arch}"),
                            digest(values.get(arch, "")),
                            False,
                        )
                    )
    # Parse and validate every candidate document before any destination changes.
    rendered = [
        render_edits(document, edits) for document, edits in zip(documents, changes)
    ]
    for path, original, candidate in zip(paths, documents, rendered):
        if candidate == original:
            continue
        descriptor, temporary = tempfile.mkstemp(
            prefix=f".{path.name}.", dir=path.parent
        )
        try:
            with os.fdopen(descriptor, "w") as stream:
                stream.write(candidate)
            os.chmod(temporary, path.stat().st_mode & 0o777)
            os.replace(temporary, path)
        finally:
            Path(temporary).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("packages", "metadata", "externals", "plan"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    try:
        apply(args.packages, args.metadata, args.externals, args.plan)
    except (ValueError, OSError, KeyError, yaml.YAMLError) as error:
        parser.exit(1, f"Cannot apply upgrade plan: {error}\n")


if __name__ == "__main__":
    main()
