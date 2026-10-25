#!/usr/bin/env bash
# Static safety contract for backup, conflict, logging, and resume behavior.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
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
  'chmod 700 "$STATE_ROOT"' \
  'chmod 600 "$LOG_FILE" "$EVENT_LOG"' \
  'acquire_bootstrap_lock' \
  'DOTFILES_LOCK_TIMEOUT' \
  'json_escape' \
  'RUN_STARTED_NANOS' \
  'bootstrap_elapsed_ms'; do
  grep -Fq "$expected" "$INSTALL" && pass "$expected" || fail "installer missing $expected"
done

if grep -Fq 'RUN_STARTED_EPOCH' "$INSTALL"; then
  fail "installer still references the removed RUN_STARTED_EPOCH timer"
else
  pass "installer uses one nanosecond-based elapsed timer"
fi

for expected in \
  'type=absent' \
  'sha256sum "$target"' \
  'preflight_restore' \
  'rmdir -- "$target"' \
  'chmod -R go-rwx' \
  'verify_backup_id' \
  'Backup verified:' \
  'scripts/backup.sh verify'; do
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

# Execute the actual recap and orchestrator loggers, using synthetic events only.
awk '/^print_run_diagnostics\(\)/ { block = 1 } /^setup_run_state$/ { block = 0 } block' \
  "$INSTALL" >"$temporary/diagnostics.sh"
awk '/^log_warn\(\)/ { block = 1 } /^log_skip\(\)/ { block = 0 } block' \
  "$INSTALL" >"$temporary/loggers.sh"
(
  EVENT_LOG="$temporary/events.jsonl" LOG_FILE="$temporary/full.log"
  export YELLOW='' RED='' NC=''
  timestamp() { printf '12:00:00'; }
  write_event() { printf '{"level":"%s","stage":"fixture","message":"%s"}\n' "$1" "$2" >>"$EVENT_LOG"; }
  source "$temporary/loggers.sh"
  source "$temporary/diagnostics.sh"
  log_warn 'preserved fixture' >"$LOG_FILE"
  log_error 'failed fixture' >>"$LOG_FILE" 2>&1
  log_warn 'preserved fixture' >>"$LOG_FILE"
  write_event high 'new major available'
  write_event low 'patch available'
  printf 'invalid interrupted event\n[]\n{"level":"info","message":"hidden"}\n' >>"$EVENT_LOG"
  print_run_diagnostics >"$temporary/recap"
  [[ "$(grep -Fc 'preserved fixture' "$temporary/recap")" == 1 ]]
  grep -Fq '[ERROR] fixture: failed fixture' "$temporary/recap"
  grep -Fq '[HIGH] fixture: new major available' "$temporary/recap"
  grep -Fq '[LOW] fixture: patch available' "$temporary/recap"
  grep -Fq 'preserved fixture' "$LOG_FILE"
  grep -Fq 'failed fixture' "$LOG_FILE"
  ! grep -Fq hidden "$temporary/recap"
  : >"$EVENT_LOG"
  print_run_diagnostics | grep -Fq 'No structured warnings or errors'
)

[[ "$FAILED" -eq 0 ]] || exit 1
printf 'Bootstrap safety test passed\n'
