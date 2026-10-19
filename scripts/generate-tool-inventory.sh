#!/usr/bin/env bash
# generate-tool-inventory.sh — Build docs/tool-inventory.md from package manifests
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PACKAGES_FILE="$DOTFILES_DIR/packages.yaml"
META_FILE="$DOTFILES_DIR/packages.meta.yaml"
OUTPUT_FILE="${1:-$DOTFILES_DIR/docs/tool-inventory.md}"

README_FILE="${2:-}"
if (($# == 0)); then
  README_FILE="$DOTFILES_DIR/README.md"
fi

PYTHONPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" /usr/bin/python3 - "$PACKAGES_FILE" "$META_FILE" "$OUTPUT_FILE" "$README_FILE" <<'PYGEN'
from __future__ import annotations

import sys
from pathlib import Path

from dotfiles.metadata import load_versions, load_metadata, validate_repository

packages_file = Path(sys.argv[1])
meta_file = Path(sys.argv[2])
output_file = Path(sys.argv[3])
readme_file = Path(sys.argv[4]) if sys.argv[4] else None


versions, metadata = validate_repository(load_versions(packages_file), load_metadata(meta_file))
output_file.parent.mkdir(parents=True, exist_ok=True)

lines = [
    "# Tool Inventory",
    "",
    "Generated from `packages.yaml` and `packages.meta.yaml`. Update manifests first, then regenerate with:",
    "",
    "```bash",
    "./scripts/generate-tool-inventory.sh",
    "```",
    "",
    "| Section | Tool | Version | Source | Owner | Integrity |",
    "|---------|------|---------|--------|-------|-----------|",
]
for section, tools in versions.items():
    for tool, version in tools.items():
        meta = metadata.get(section, {}).get(tool, {})
        lines.append(
            f"| {section} | {tool} | {version} | {meta.get('source', 'unknown')} "
            f"| {meta.get('owner', 'unknown')} | {meta.get('integrity', 'missing')} |"
        )

output_file.write_text("\n".join(lines) + "\n")

if readme_file is not None:
    start = "<!-- tool-versions:start -->"
    end = "<!-- tool-versions:end -->"
    text = readme_file.read_text()
    if text.count(start) != 1 or text.count(end) != 1:
        raise SystemExit("README must contain exactly one tool-versions block")
    before, remaining = text.split(start)
    _, after = remaining.split(end)
    rows = ["", "| Category | Tools and Requested Versions |", "| --- | --- |"]
    for section, tools in versions.items():
        entries = ", ".join(f"`{tool}` {version}" for tool, version in tools.items())
        rows.append(f"| {section} | {entries} |")
    readme_file.write_text(before + start + "\n".join(rows) + "\n" + end + after)
PYGEN
