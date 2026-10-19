"""Validated, ordered package manifests shared by Python and shell consumers.

Numeric-looking scalars stay strings so versions and digests are never rounded or
reformatted by YAML's implicit numeric and timestamp conversions.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    raise SystemExit("Package metadata requires python3-yaml; rerun the core section")


class MetadataError(ValueError):
    """An invalid manifest, including its path and location where available."""


class _Loader(yaml.SafeLoader):
    pass


_Loader.yaml_implicit_resolvers = {
    key: [
        (tag, pattern)
        for tag, pattern in resolvers
        if tag
        not in {
            "tag:yaml.org,2002:int",
            "tag:yaml.org,2002:float",
            "tag:yaml.org,2002:timestamp",
        }
    ]
    for key, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


def _mapping(loader, node, deep=False):
    loader.flatten_mapping(node)
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if not isinstance(key, str):
            raise MetadataError(f"{key_node.start_mark}: mapping keys must be strings")
        if key in result:
            raise MetadataError(f"{key_node.start_mark}: duplicate key {key!r}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


_Loader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)
_NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\Z")
_SHA256 = re.compile(r"[0-9a-fA-F]{64}\Z")


def _load(path):
    path = Path(path)
    try:
        data = yaml.load(path.read_text(), Loader=_Loader)
    except (OSError, UnicodeError, yaml.YAMLError, MetadataError) as error:
        raise MetadataError(f"{path}: {error}") from error
    if not isinstance(data, dict) or not data:
        raise MetadataError(f"{path}: expected a nonempty section mapping")
    return data


def _named_mapping(value, location):
    if not isinstance(value, dict):
        raise MetadataError(f"{location}: expected a mapping")
    for key in value:
        if not isinstance(key, str) or not _NAME.fullmatch(key):
            raise MetadataError(f"{location}: invalid name {key!r}")
    return value


def _scalar(value, location):
    if not isinstance(value, str) or not value.strip():
        raise MetadataError(f"{location}: expected a nonempty string scalar")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise MetadataError(f"{location}: control characters are not allowed")
    return value


def load_versions(path):
    """Return section -> tool -> requested version, preserving manifest order."""
    data = _named_mapping(_load(path), str(path))
    for section, tools in data.items():
        for name, value in _named_mapping(tools, f"{path}:{section}").items():
            _scalar(value, f"{path}:{section}.{name}")
    return data


def load_metadata(path):
    """Return section -> tool -> scalar metadata, validating integrity fields."""
    data = _named_mapping(_load(path), str(path))
    for section, tools in data.items():
        for name, fields in _named_mapping(tools, f"{path}:{section}").items():
            location = f"{path}:{section}.{name}"
            for field, value in _named_mapping(fields, location).items():
                _scalar(value, f"{location}.{field}")
                if field == "sha256" or field.startswith("sha256_"):
                    if not _SHA256.fullmatch(value):
                        raise MetadataError(
                            f"{location}.{field}: expected a SHA256 digest"
                        )
            for field in ("source", "owner", "integrity"):
                if fields.get(field) in (None, "missing", "null", "unknown"):
                    raise MetadataError(f"{location}: missing {field}")
            if (
                fields["integrity"] == "pinned-sha256"
                and fields["source"] != "external"
            ):
                if not (
                    fields.get("sha256")
                    or (fields.get("sha256_amd64") and fields.get("sha256_arm64"))
                ):
                    raise MetadataError(
                        f"{location}: missing sha256 or sha256_amd64+sha256_arm64"
                    )
    return data


def validate_repository(versions, metadata):
    """Require exact tool coverage between versions and installation metadata."""
    requested = {
        (section, name) for section, tools in versions.items() for name in tools
    }
    described = {
        (section, name) for section, tools in metadata.items() for name in tools
    }
    missing = requested - described
    extra = described - requested
    if missing or extra:
        details = []
        if missing:
            details.append(
                "missing metadata: " + ", ".join(f"{s}.{n}" for s, n in sorted(missing))
            )
        if extra:
            details.append(
                "metadata without version: "
                + ", ".join(f"{s}.{n}" for s, n in sorted(extra))
            )
        raise MetadataError("; ".join(details))
    return versions, metadata


def load_repository(root):
    root = Path(root)
    return validate_repository(
        load_versions(root / "packages.yaml"),
        load_metadata(root / "packages.meta.yaml"),
    )


def section_manifest_hash(path, section):
    """Keep legacy section-text digests, using YAML locations instead of regexes."""
    data = load_versions(path)
    text = Path(path).read_text()
    document = yaml.compose(text, Loader=_Loader)
    if document.flow_style:
        encoded = json.dumps(
            data.get(section, {}), sort_keys=True, separators=(",", ":")
        )
    else:
        encoded = ""
        lines = text.splitlines()
        for index, (key, _) in enumerate(document.value):
            if key.value == section:
                stop = (
                    document.value[index + 1][0].start_mark.line
                    if index + 1 < len(document.value)
                    else len(lines)
                )
                encoded = "".join(
                    line + "\n" for line in lines[key.start_mark.line : stop]
                )
                break
    return hashlib.sha256(encoded.encode()).hexdigest()


def release_spec(meta, version, arch):
    """Render a GitHub release from metadata using the canonical host arch.

    Both {arch} and {release_arch} refer to the mapped vendor architecture.
    Architecture-specific asset templates take precedence over the common one.
    """
    if arch not in {"amd64", "arm64"}:
        raise MetadataError(f"Unsupported release architecture: {arch}")
    version = version.removeprefix("v")
    release_arch = meta.get(f"arch_{arch}", arch)
    values = {"version": version, "arch": release_arch, "release_arch": release_arch}
    try:
        tag = meta.get("tag_template", "v{version}").format_map(values)
        values["tag"] = tag
        template = meta.get(f"asset_template_{arch}", meta.get("asset_template"))
        if not template:
            raise MetadataError("Missing release asset template")
        return {"repo": meta["repo"], "tag": tag, "asset": template.format_map(values)}
    except (KeyError, ValueError) as error:
        raise MetadataError(f"Invalid release metadata: {error}") from error


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    release = subparsers.add_parser("release-spec")
    release.add_argument("metadata", type=Path)
    release.add_argument("packages", type=Path)
    release.add_argument("tool")
    rendered = subparsers.add_parser("release-field")
    rendered.add_argument("path", type=Path)
    rendered.add_argument("section")
    rendered.add_argument("tool")
    rendered.add_argument("version")
    rendered.add_argument("arch", choices=("amd64", "arm64"))
    rendered.add_argument("field", choices=("repo", "tag", "asset"))
    for command in ("version", "field", "section-hash"):
        sub = subparsers.add_parser(command)
        sub.add_argument("path", type=Path)
        sub.add_argument("section")
        if command != "section-hash":
            sub.add_argument("tool")
            if command == "field":
                sub.add_argument("field")
            sub.add_argument("default", nargs="?", default="")
    args = parser.parse_args(argv)
    try:
        if args.command == "release-spec":
            versions, metadata = validate_repository(
                load_versions(args.packages), load_metadata(args.metadata)
            )
            section, separator, name = args.tool.partition(".")
            if not separator:
                raise MetadataError(f"Expected section.tool, got {args.tool!r}")
            meta = metadata.get(section, {}).get(name, {})
            fields = [
                meta.get(field, "")
                for field in (
                    "repo",
                    "tag_template",
                    "asset_template",
                    "arch_amd64",
                    "arch_arm64",
                )
            ]
            if not all(fields):
                raise MetadataError(
                    f"No complete release specification for {args.tool}"
                )
            fields[2] = fields[2].replace(
                "{font}", versions.get("fonts", {}).get("nerd_font", "FiraMono")
            )
            if any("|" in value for value in fields):
                raise MetadataError(
                    f"Invalid release specification delimiter for {args.tool}"
                )
            print("|".join(fields))
        elif args.command == "release-field":
            metadata = load_metadata(args.path)
            spec = release_spec(
                metadata.get(args.section, {}).get(args.tool, {}),
                args.version,
                args.arch,
            )
            print(spec[args.field])
        elif args.command == "field":
            data = load_metadata(args.path)
            print(
                data.get(args.section, {})
                .get(args.tool, {})
                .get(args.field, args.default)
            )
        else:
            data = load_versions(args.path)
            if args.command == "version":
                print(data.get(args.section, {}).get(args.tool, args.default))
            else:
                print(section_manifest_hash(args.path, args.section))
    except MetadataError as error:
        parser.exit(1, f"{error}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
