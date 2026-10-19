#!/usr/bin/env bash
# generate-package-lock.sh — Build packages.lock from packages.yaml and metadata
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PACKAGES_FILE="$DOTFILES_DIR/packages.yaml"
META_FILE="$DOTFILES_DIR/packages.meta.yaml"
OUTPUT_FILE="${1:-$DOTFILES_DIR/packages.lock}"

PYTHONPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" /usr/bin/python3 - "$PACKAGES_FILE" "$META_FILE" "$OUTPUT_FILE" <<'PYGEN'
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

from dotfiles.metadata import load_versions, load_metadata, validate_repository

packages_file = Path(sys.argv[1])
meta_file = Path(sys.argv[2])
output_file = Path(sys.argv[3])

def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def yaml_scalar(value: str) -> str:
    if value == "":
        return '""'
    safe = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
    if all(char in safe for char in value):
        return value
    return '"' + value.replace('\\', '\\\\').replace('\"', '\\"') + '"'

versions, metadata = validate_repository(load_versions(packages_file), load_metadata(meta_file))
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
            "tag_template",
            "asset_template",
            "arch_amd64",
            "arch_arm64",
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
