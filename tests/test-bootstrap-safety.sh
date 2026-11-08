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
  DOTFILES_VERBOSE=1 print_run_diagnostics >"$temporary/recap"
  [[ "$(grep -Fc 'preserved fixture' "$temporary/recap")" == 1 ]]
  grep -Fq '[ERROR] fixture: failed fixture' "$temporary/recap"
  grep -Fq '[HIGH] fixture: new major available' "$temporary/recap"
  grep -Fq '[LOW] fixture: patch available' "$temporary/recap"
  grep -Fq 'preserved fixture' "$LOG_FILE"
  grep -Fq 'failed fixture' "$LOG_FILE"
  ! grep -Fq hidden "$temporary/recap"
  DOTFILES_VERBOSE=0 print_run_diagnostics >"$temporary/compact"
  ! grep -Fq 'preserved fixture' "$temporary/compact"
  grep -Fq '1 warn' "$temporary/compact"
  : >"$EVENT_LOG"
  print_run_diagnostics | grep -Fq 'No structured warnings or errors'
)

[[ "$FAILED" -eq 0 ]] || exit 1

awk '/^read_user\(\)/ { block = 1 } /^read_menu_user\(\)/ { block = 0 } block' \
  "$INSTALL" >"$temporary/read-user.sh"
(
  source "$temporary/read-user.sh"
  export HAS_CONTROLLING_TTY=false READ_USER_ALLOW_STDIN=true
  INTERACTIVE_WAIT_MS=0 choice=''
  read_user 'Fixture choice: ' choice < <(
    sleep 0.05
    printf 'r\n'
  )
  [[ "$choice" == r && "$INTERACTIVE_WAIT_MS" -ge 30 ]]
)
mkdir -p "$temporary/vendor/scripts"
cat >"$temporary/vendor/scripts/lib.sh" <<'VENDOR'
package_metadata() { printf '%s\n' "$3"; }
log_info() { :; }
log_error() { :; }
command() {
  if [[ "$1" == -v ]]; then
    [[ "${VENDOR_PRESENT:-0}" == 0 ]] || printf '/fixture/bin/%s\n' "$2"
    return 0
  fi
  builtin command "$@"
}
download_vendor_installer() {
  printf '%s\n' "$1" >>"$VENDOR_CALLS"
  [[ "${VENDOR_FAIL:-0}" == 0 ]]
}
VENDOR
export VENDOR_CALLS="$temporary/vendor-calls"
DOTFILES_SOURCE_DIR="$temporary/vendor" bash "$DOTFILES_DIR/scripts/vendor-preflight.sh"
[[ "$(wc -l <"$VENDOR_CALLS")" == 2 ]]
: >"$VENDOR_CALLS"
VENDOR_PRESENT=1 DOTFILES_SOURCE_DIR="$temporary/vendor" bash "$DOTFILES_DIR/scripts/vendor-preflight.sh"
[[ ! -s "$VENDOR_CALLS" ]]
if VENDOR_FAIL=1 DOTFILES_SOURCE_DIR="$temporary/vendor" bash "$DOTFILES_DIR/scripts/vendor-preflight.sh"; then
  printf 'Vendor preflight accepted failed integrity verification\n' >&2
  exit 1
fi

# Exercise the actual lock helper across abrupt owner death with a live child.
awk '/^acquire_bootstrap_lock\(\)/ { block = 1 } /^acquire_bootstrap_lock \|\|/ { block = 0 } block' \
  "$INSTALL" >"$temporary/lock-functions.sh"
(
  export STATE_ROOT="$temporary/lock-state" DOTFILES_LOCK_TIMEOUT=0
  mkdir -p "$STATE_ROOT"
  bash -c '
    source "$1"
    acquire_bootstrap_lock
    sleep 2 &
    echo "$!" >"$STATE_ROOT/child"
    echo "$BASHPID" >"$STATE_ROOT/owner"
    wait
  ' bash "$temporary/lock-functions.sh" &
  owner=$!
  for _ in {1..100}; do
    [[ ! -f "$STATE_ROOT/child" ]] || break
    sleep 0.02
  done
  [[ -f "$STATE_ROOT/child" ]]
  kill -KILL "$owner"
  wait "$owner" 2>/dev/null || true
  if flock -n "$STATE_ROOT/bootstrap.lock" true; then
    printf 'Owner death released the lock before the mutation child exited\n' >&2
    exit 1
  fi
  flock -w 5 "$STATE_ROOT/bootstrap.lock" true
)
awk '/^run_stage\(\)/ { block = 1 } /^bootstrap_download\(\)/ { block = 0 } block' \
  "$INSTALL" >"$temporary/run-stage.sh"
(
  source "$temporary/run-stage.sh"
  CHECKPOINT_DIR="$temporary/checkpoints"
  mkdir -p "$CHECKPOINT_DIR"
  # Used by the sourced run_stage function.
  # shellcheck disable=SC2034
  SELECTED_SECTIONS=(detect)
  export STAGE_NUMBER=0 RESUME_REQUEST='' ONLY_SECTION='' RUN_DOCTOR=false
  log_step() { printf '%s\n' "$*"; }
  log_success() { :; }
  write_event() { :; }
  format_bootstrap_duration_seconds() { printf '%ss' "$1"; }
  stage_injection_matches() { return 1; }
  run_stage fixture true >"$temporary/stage-output"
  grep -Fq '[1/6] fixture' "$temporary/stage-output"
  [[ -f "$CHECKPOINT_DIR/fixture.done" ]]
)
printf 'Bootstrap safety test passed\n'
