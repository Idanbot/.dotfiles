#!/usr/bin/env bash
# Verify concurrent bootstraps fail before touching run state.

set -euo pipefail

DOTFILES_DIR=""
if [[ $# -gt 0 ]]; then
  DOTFILES_DIR="$1"
fi
if [[ -z "$DOTFILES_DIR" ]]; then
  DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fi
INSTALL="$DOTFILES_DIR/scripts/install.sh"
TEST_HOME="$(mktemp -d)"
STATE_ROOT="$TEST_HOME/.local/state/dotfiles"
trap 'rm -rf "$TEST_HOME"' EXIT

mkdir -p "$STATE_ROOT"
exec 9>"$STATE_ROOT/bootstrap.lock"
flock -n 9

set +e
output="$(
  HOME="$TEST_HOME" \
    DOTFILES_STATE_DIR="$STATE_ROOT" \
    DOTFILES_COLOR=never \
    DOTFILES_LOG=0 \
    "$INSTALL" --source "$DOTFILES_DIR" --profile minimal --yes --no-doctor 2>&1
)"
status=$?
set -e

[[ "$status" -ne 0 ]] || {
  printf 'concurrent bootstrap unexpectedly succeeded\n%s\n' "$output" >&2
  exit 1
}
grep -Fq 'Another dotfiles bootstrap is already running' <<<"$output"
[[ ! -e "$STATE_ROOT/runs" ]]
[[ "$(stat -c '%a' "$STATE_ROOT/bootstrap.lock")" == 600 ]]

set +e
wait_output="$(
  HOME="$TEST_HOME" \
    DOTFILES_STATE_DIR="$STATE_ROOT" \
    DOTFILES_COLOR=never \
    DOTFILES_LOG=0 \
    "$INSTALL" --source "$DOTFILES_DIR" --profile minimal --yes --no-doctor --lock-timeout 1 2>&1
)"
wait_status=$?
set -e
[[ "$wait_status" -ne 0 ]]
grep -Fq 'Timed out after 1s waiting' <<<"$wait_output"

set +e
invalid_output="$(
  HOME="$TEST_HOME" \
    DOTFILES_STATE_DIR="$TEST_HOME/invalid-state" \
    "$INSTALL" --profile minimal --lock-timeout invalid --print-plan 2>&1
)"
invalid_status=$?
set -e
[[ "$invalid_status" -eq 2 ]]
grep -Fq 'Invalid lock timeout' <<<"$invalid_output"

# A logged run creates tee/sed processes. Verify those descendants do not keep
# the bootstrap lock held after either a successful or failed run.
exec 9>&-

assert_no_lock_ipc() {
  local state_root="$1"
  if compgen -G "$state_root/.bootstrap-lock-ready-*" >/dev/null ||
    compgen -G "$state_root/.bootstrap-lock-error-*" >/dev/null ||
    compgen -G "$state_root/.bootstrap-lock-release-*" >/dev/null; then
    printf 'bootstrap lock helper artifacts remain in %s\n' "$state_root" >&2
    return 1
  fi
}

lifecycle_home="$TEST_HOME/lifecycle-home"
lifecycle_state="$TEST_HOME/lifecycle-state"
lifecycle_source="$TEST_HOME/lifecycle-source"
mkdir -p "$lifecycle_home" "$lifecycle_state" \
  "$lifecycle_source/.chezmoiscripts" "$lifecycle_source/scripts"
cp "$DOTFILES_DIR/.chezmoi.yaml.tmpl" "$lifecycle_source/.chezmoi.yaml.tmpl"
cp "$DOTFILES_DIR/scripts/environment.sh" "$lifecycle_source/scripts/environment.sh"
cp "$DOTFILES_DIR/scripts/conflicts.sh" "$lifecycle_source/scripts/conflicts.sh"
cp "$DOTFILES_DIR/scripts/run-plan.py" "$DOTFILES_DIR/scripts/section-state.py" "$DOTFILES_DIR/scripts/sections.json" "$lifecycle_source/scripts/"
cp "$DOTFILES_DIR/packages.yaml" "$DOTFILES_DIR/packages.meta.yaml" "$lifecycle_source/"
printf '%s\n' 'bootstrap lock lifecycle fixture' >"$lifecycle_source/dot_bootstrap-lock-fixture"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "lock lifecycle section executed\\n"' \
  >"$lifecycle_source/.chezmoiscripts/run_once_before_00-detect-environment.sh.tmpl"
chmod 755 "$lifecycle_source/.chezmoiscripts/run_once_before_00-detect-environment.sh.tmpl"
lifecycle_path="$lifecycle_home/.local/bin:$PATH"

for pass in 1 2; do
  set +e
  lifecycle_output="$(
    PATH="$lifecycle_path" \
      HOME="$lifecycle_home" \
      DOTFILES_STATE_DIR="$lifecycle_state" \
      DOTFILES_COLOR=never \
      DOTFILES_LOG=1 \
      DOTFILES_CONFLICT_POLICY=skip \
      DOTFILES_LOG_FILE="$lifecycle_home/bootstrap-pass-$pass.log" \
      "$INSTALL" --source "$lifecycle_source" --sections detect --yes --no-doctor 2>&1
  )"
  lifecycle_status=$?
  set -e
  [[ "$lifecycle_status" -eq 0 ]] || {
    printf 'logged bootstrap pass %s failed (exit %s)\n%s\n' \
      "$pass" "$lifecycle_status" "$lifecycle_output" >&2
    exit 1
  }
  grep -Fq 'Bootstrap Complete' <<<"$lifecycle_output"
  [[ -s "$lifecycle_home/bootstrap-pass-$pass.log" ]]
  assert_no_lock_ipc "$lifecycle_state"
done

failure_home="$lifecycle_home"
failure_state="$lifecycle_state"

set +e
failure_output="$(
  PATH="$lifecycle_path" \
    HOME="$failure_home" \
    DOTFILES_STATE_DIR="$failure_state" \
    DOTFILES_COLOR=never \
    DOTFILES_LOG=1 \
    DOTFILES_CONFLICT_POLICY=skip \
    DOTFILES_LOG_FILE="$failure_home/bootstrap-failed.log" \
    DOTFILES_FAIL_AT=section-detect:before \
    "$INSTALL" --source "$lifecycle_source" --sections detect --yes --no-doctor 2>&1
)"
failure_status=$?
set -e
[[ "$failure_status" -eq 97 ]] || {
  printf 'injected bootstrap failure returned %s\n%s\n' \
    "$failure_status" "$failure_output" >&2
  exit 1
}
grep -Fq 'Injected failure before section-detect' <<<"$failure_output"
assert_no_lock_ipc "$failure_state"
failed_run_id="$(<"$failure_state/runs/latest")"
[[ -f "$failure_state/runs/$failed_run_id/plan.json" ]]

set +e
recovery_output="$(
  PATH="$lifecycle_path" \
    HOME="$failure_home" \
    DOTFILES_STATE_DIR="$failure_state" \
    DOTFILES_COLOR=never \
    DOTFILES_LOG=1 \
    DOTFILES_CONFLICT_POLICY=skip \
    DOTFILES_LOG_FILE="$failure_home/bootstrap-recovered.log" \
    "$INSTALL" --resume="$failed_run_id" --yes 2>&1
)"
recovery_status=$?
set -e
[[ "$recovery_status" -eq 0 ]] || {
  printf 'bootstrap recovery failed (exit %s)\n%s\n' \
    "$recovery_status" "$recovery_output" >&2
  exit 1
}
grep -Fq 'Bootstrap Complete' <<<"$recovery_output"
grep -Fq 'apply already completed' <<<"$recovery_output"
[[ "$(find "$failure_state/runs/$failed_run_id/attempts" -name '*.json' | wc -l)" -eq 2 ]]
jq -e '.status == "success"' "$failure_state/runs/$failed_run_id/summary.json" >/dev/null
assert_no_lock_ipc "$failure_state"

printf 'changed input\n' >>"$lifecycle_source/dot_bootstrap-lock-fixture"
if changed_output="$(HOME="$failure_home" DOTFILES_STATE_DIR="$failure_state" \
  DOTFILES_LOG=0 "$INSTALL" --resume="$failed_run_id" --yes 2>&1)"; then
  printf 'resume accepted changed source\n' >&2
  exit 1
fi
grep -Fq 'Resume inputs changed' <<<"$changed_output"
[[ "$(find "$failure_state/runs/$failed_run_id/attempts" -name '*.json' | wc -l)" -eq 3 ]]

# A completed doctor checkpoint must not suppress fresh health validation.
cp "$DOTFILES_DIR/scripts/backup.sh" "$lifecycle_source/scripts/backup.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "checked\n" >>"$HOME/doctor-calls"' \
  >"$lifecycle_source/scripts/doctor.sh"
chmod +x "$lifecycle_source/scripts/doctor.sh"
mkdir -p "$failure_home/.local/bin"
for helper in dot dot-privacy; do
  printf '#!/bin/sh\nexit 0\n' >"$failure_home/.local/bin/$helper"
  chmod +x "$failure_home/.local/bin/$helper"
done
set +e
doctor_output="$(HOME="$failure_home" DOTFILES_STATE_DIR="$failure_state" \
  DOTFILES_LOG=0 DOTFILES_FAIL_AT=doctor:after \
  "$INSTALL" --source "$lifecycle_source" --sections detect --yes 2>&1)"
doctor_status=$?
set -e
[[ "$doctor_status" -eq 98 ]] || {
  printf '%s\n' "$doctor_output"
  exit 1
}
doctor_run="$(<"$failure_state/runs/latest")"
backup_id="$(<"$failure_state/runs/$doctor_run/backup-id")"
[[ -n "$backup_id" && -f "$failure_state/runs/$doctor_run/checkpoints/doctor.done" ]]
HOME="$failure_home" DOTFILES_STATE_DIR="$failure_state" DOTFILES_LOG=0 \
  "$INSTALL" --resume="$doctor_run" --yes >"$failure_home/doctor-resume.log" 2>&1 || {
  cat "$failure_home/doctor-resume.log"
  exit 1
}
[[ "$(wc -l <"$failure_home/doctor-calls")" -eq 2 ]]
jq -e --arg backup "$backup_id" '.status == "success" and .backup_id == $backup' \
  "$failure_state/runs/$doctor_run/summary.json" >/dev/null
[[ "$(find "$failure_state/runs/$doctor_run/attempts" -name '*.json' | wc -l)" -eq 2 ]]

printf 'Bootstrap lock test passed\n'
