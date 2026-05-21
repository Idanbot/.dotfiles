#!/usr/bin/env bash
# test-package-metadata.sh — Validate package metadata, lock, and generated docs
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
FAILED=0

pass() { echo -e "  ${GREEN}✓${NC} $*"; }
fail() {
  echo -e "  ${RED}✗${NC} $*"
  FAILED=1
}

echo -e "\n${BOLD}══ Package Metadata Test ══${NC}\n"

for file in packages.yaml packages.meta.yaml packages.lock docs/tool-inventory.md docs/keybindings.md; do
  if [[ -f "$DOTFILES_DIR/$file" ]]; then
    pass "$file exists"
  else
    fail "$file is missing"
  fi
done

if python3 - "$DOTFILES_DIR/packages.yaml" "$DOTFILES_DIR/packages.meta.yaml" <<'PYTEST'; then
import sys
from pathlib import Path

versions = Path(sys.argv[1])
metadata = Path(sys.argv[2])

def keys(path):
    result = []
    section = ""
    for raw in path.read_text().splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not raw.startswith(" ") and line.endswith(":"):
            section = line[:-1].strip()
        elif section and raw.startswith("  ") and not raw.startswith("    ") and ":" in line:
            result.append((section, line.split(":", 1)[0].strip()))
    return result

def sources(path):
    result = set()
    section = ""
    tool = ""
    for raw in path.read_text().splitlines():
        line = raw.rstrip()
        indent = len(raw) - len(raw.lstrip(" "))
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if indent == 0 and line.endswith(":"):
            section = line[:-1].strip()
        elif indent == 2 and line.endswith(":"):
            tool = line[:-1].strip()
        elif indent == 4 and line.strip().startswith("source:"):
            result.add((section, tool))
    return result

missing = sorted(set(keys(versions)) - sources(metadata))
if missing:
    for section, tool in missing:
        print(f"missing source metadata: {section}.{tool}")
    raise SystemExit(1)
PYTEST
  pass "all packages have source metadata"
else
  fail "some packages are missing source metadata"
fi

tmp_lock=$(mktemp)
"$DOTFILES_DIR/scripts/generate-package-lock.sh" "$tmp_lock"
if cmp -s "$tmp_lock" "$DOTFILES_DIR/packages.lock"; then
  pass "packages.lock is up to date"
else
  fail "packages.lock is stale"
fi
rm -f "$tmp_lock"

tmp_inventory=$(mktemp)
"$DOTFILES_DIR/scripts/generate-tool-inventory.sh" "$tmp_inventory"
if cmp -s "$tmp_inventory" "$DOTFILES_DIR/docs/tool-inventory.md"; then
  pass "tool inventory is up to date"
else
  fail "tool inventory is stale"
fi
rm -f "$tmp_inventory"

tmp_keys=$(mktemp)
"$DOTFILES_DIR/scripts/generate-keybinding-docs.sh" "$tmp_keys"
if cmp -s "$tmp_keys" "$DOTFILES_DIR/docs/keybindings.md"; then
  pass "keybinding docs are up to date"
else
  fail "keybinding docs are stale"
fi
rm -f "$tmp_keys"

if [[ $FAILED -gt 0 ]]; then
  echo -e "\n${RED}${BOLD}PACKAGE METADATA TEST FAILED${NC}"
  exit 1
fi

echo -e "\n${GREEN}${BOLD}PACKAGE METADATA TEST PASSED${NC}"
