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

if PYTHONPATH="$DOTFILES_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}" /usr/bin/python3 - "$DOTFILES_DIR" <<'PYTEST'; then
import sys
from dotfiles.metadata import load_repository

load_repository(sys.argv[1])
PYTEST
  pass "all packages have source, owner, and integrity metadata"
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
tmp_readme=$(mktemp)
cp "$DOTFILES_DIR/README.md" "$tmp_readme"
"$DOTFILES_DIR/scripts/generate-tool-inventory.sh" "$tmp_inventory" "$tmp_readme"
if cmp -s "$tmp_inventory" "$DOTFILES_DIR/docs/tool-inventory.md"; then
  pass "tool inventory is up to date"
else
  fail "tool inventory is stale"
fi
if cmp -s "$tmp_readme" "$DOTFILES_DIR/README.md"; then
  pass "README tool versions are up to date"
else
  fail "README tool versions are stale"
fi
rm -f "$tmp_inventory" "$tmp_readme"

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
