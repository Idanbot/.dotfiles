#!/usr/bin/env bash
# Static safety contract for backup, conflict, logging, and resume behavior.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
FAILED=0
pass() { printf '  [PASS] %s\n' "$*"; }
fail() {
  printf '  [FAIL] %s\n' "$*"
  FAILED=1
}

INSTALL="$DOTFILES_DIR/scripts/install.sh"
BACKUP="$DOTFILES_DIR/scripts/backup.sh"

for expected in \
  'DOTFILES_CONFLICT_POLICY="${DOTFILES_CONFLICT_POLICY:-backup}"' \
  'DOTFILES_ROLLBACK_ON_ERROR' \
  'write_run_summary failure' \
  'Resume after fixing the cause' \
  'sed -u -E' \
  'chmod 600 "$LOG_FILE" "$EVENT_LOG"'; do
  grep -Fq "$expected" "$INSTALL" && pass "$expected" || fail "installer missing $expected"
done

for expected in 'type=absent' 'sha256sum "$target"' 'rm -rf -- "$target"' 'chmod -R go-rwx'; do
  grep -Fq "$expected" "$BACKUP" && pass "backup contract: $expected" || fail "backup missing $expected"
done

if grep -Eq 'age-keygen|APPLY_EXCLUDES.*encrypted|Age Identity Key Required' "$INSTALL"; then
  fail "public bootstrap still creates or requires an age identity"
else
  pass "bootstrap is explicitly secret-free"
fi

if grep -Fq '[[ -n "$CHEZMOI_STATUS_OUTPUT" ]] || return 0' "$INSTALL"; then
  fail "clean config status incorrectly skips chezmoi externals"
else
  pass "clean config status still converges checksum-pinned externals"
fi

[[ "$FAILED" -eq 0 ]] || exit 1
printf 'Bootstrap safety test passed\n'
