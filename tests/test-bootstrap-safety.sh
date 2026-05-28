#!/usr/bin/env bash
# test-bootstrap-safety.sh - Validate bootstrap dry-run/conflict helpers
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
INSTALL_SCRIPT="$DOTFILES_DIR/scripts/install.sh"
FAILED=0

pass() { echo "  ✓ $*"; }
fail() {
  echo "  ✗ $*"
  FAILED=1
}

for expected in \
  'Chezmoi Dry Run' \
  'Dry-run diff command: chezmoi diff' \
  'DOTFILES_DIFF_PREVIEW=1' \
  'Writing run log to' \
  'diff: show the current file diff, then ask again' \
  'all-overwrite: replace this and all remaining conflicted files' \
  'Chezmoi would create' \
  'Noninteractive run: backing up conflicts before apply' \
  'Backed up ~/' \
  'Skipping chezmoi apply because local conflicts were preserved'; do
  if grep -Fq "$expected" "$INSTALL_SCRIPT"; then
    pass "bootstrap includes: $expected"
  else
    fail "bootstrap missing: $expected"
  fi
done

if [[ $FAILED -gt 0 ]]; then
  echo "BOOTSTRAP SAFETY TEST FAILED"
  exit 1
fi

echo "BOOTSTRAP SAFETY TEST PASSED"
