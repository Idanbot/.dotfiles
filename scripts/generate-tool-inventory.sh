#!/usr/bin/env bash
# generate-tool-inventory.sh — Build docs/tool-inventory.md from package manifests
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PACKAGES_FILE="$DOTFILES_DIR/packages.yaml"
META_FILE="$DOTFILES_DIR/packages.meta.yaml"
OUTPUT_FILE="${1:-$DOTFILES_DIR/docs/tool-inventory.md}"

python3 - "$PACKAGES_FILE" "$META_FILE" "$OUTPUT_FILE" <<'PYGEN'
from __future__ import annotations

import sys
from pathlib import Path

packages_file = Path(sys.argv[1])
meta_file = Path(sys.argv[2])
output_file = Path(sys.argv[3])


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
        elif section and raw.startswith("  ") and not raw.startswith("    ") and ":" in line:
            key, value = line.split(":", 1)
            data[section][key.strip()] = strip_value(value)
    return data


def parse_sources(path: Path) -> dict[tuple[str, str], str]:
    sources: dict[tuple[str, str], str] = {}
    section = ""
    tool = ""
    for raw in path.read_text().splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if indent == 0 and line.endswith(":"):
            section = line[:-1].strip()
        elif indent == 2 and line.endswith(":"):
            tool = line[:-1].strip()
        elif indent == 4 and line.strip().startswith("source:"):
            sources[(section, tool)] = strip_value(line.split(":", 1)[1])
    return sources

versions = parse_versions(packages_file)
sources = parse_sources(meta_file) if meta_file.exists() else {}
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
    "| Section | Tool | Version | Source |",
    "|---------|------|---------|--------|",
]
for section, tools in versions.items():
    for tool, version in tools.items():
        lines.append(f"| {section} | {tool} | {version} | {sources.get((section, tool), 'unknown')} |")

output_file.write_text("\n".join(lines) + "\n")
PYGEN
