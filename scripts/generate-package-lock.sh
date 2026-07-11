#!/usr/bin/env bash
# generate-package-lock.sh — Build packages.lock from packages.yaml and metadata
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PACKAGES_FILE="$DOTFILES_DIR/packages.yaml"
META_FILE="$DOTFILES_DIR/packages.meta.yaml"
OUTPUT_FILE="${1:-$DOTFILES_DIR/packages.lock}"

python3 - "$PACKAGES_FILE" "$META_FILE" "$OUTPUT_FILE" <<'PYGEN'
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

packages_file = Path(sys.argv[1])
meta_file = Path(sys.argv[2])
output_file = Path(sys.argv[3])

if not packages_file.exists():
    raise SystemExit(f"Missing packages manifest: {packages_file}")
if not meta_file.exists():
    raise SystemExit(f"Missing package metadata: {meta_file}")


def strip_value(value: str) -> str:
    value = value.split("#", 1)[0].strip()
    return value.strip('"\'')


def parse_versions(path: Path) -> dict[str, dict[str, str]]:
    data: dict[str, dict[str, str]] = {}
    section = ""
    for raw in path.read_text().splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not raw.startswith(" ") and line.endswith(":"):
            section = line[:-1].strip()
            data[section] = {}
            continue
        if section and raw.startswith("  ") and not raw.startswith("    ") and ":" in line:
            key, value = line.split(":", 1)
            data[section][key.strip()] = strip_value(value)
    return data


def parse_meta(path: Path) -> dict[str, dict[str, dict[str, str]]]:
    data: dict[str, dict[str, dict[str, str]]] = {}
    section = ""
    tool = ""
    for raw in path.read_text().splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if indent == 0 and line.endswith(":"):
            section = line[:-1].strip()
            data[section] = {}
            tool = ""
        elif indent == 2 and line.endswith(":"):
            tool = line[:-1].strip()
            data.setdefault(section, {})[tool] = {}
        elif indent == 4 and ":" in line and section and tool:
            key, value = line.split(":", 1)
            data[section][tool][key.strip()] = strip_value(value)
    return data


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def yaml_scalar(value: str) -> str:
    if value == "":
        return '""'
    safe = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
    if all(char in safe for char in value):
        return value
    return '"' + value.replace('\\', '\\\\').replace('\"', '\\"') + '"'

versions = parse_versions(packages_file)
metadata = parse_meta(meta_file)
lines = [
    "# packages.lock — generated from packages.yaml and packages.meta.yaml",
    "# Regenerate with: ./scripts/generate-package-lock.sh",
    "",
    "generated_from:",
    f"  packages: {sha(packages_file)}",
    f"  metadata: {sha(meta_file)}",
    "",
    "tools:",
]

for section, tools in versions.items():
    for name, version in tools.items():
        meta = metadata.get(section, {}).get(name, {})
        lines.extend([
            f"  - section: {yaml_scalar(section)}",
            f"    name: {yaml_scalar(name)}",
            f"    version: {yaml_scalar(version)}",
            f"    source: {yaml_scalar(meta.get('source', 'unknown'))}",
        ])
        for field in (
            "owner",
            "repo",
            "package",
            "crate",
            "binary",
            "url",
            "asset_template",
            "checksum_template",
            "sha256",
            "sha256_amd64",
            "sha256_arm64",
        ):
            if field in meta:
                lines.append(f"    {field}: {yaml_scalar(meta[field])}")
        lines.append(f"    integrity: {yaml_scalar(meta.get('integrity', 'missing'))}")

output_file.write_text("\n".join(lines) + "\n")
PYGEN
