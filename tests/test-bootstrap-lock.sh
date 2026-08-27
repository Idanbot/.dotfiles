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

set +e
recovery_output="$(
  PATH="$lifecycle_path" \
    HOME="$failure_home" \
    DOTFILES_STATE_DIR="$failure_state" \
    DOTFILES_COLOR=never \
    DOTFILES_LOG=1 \
    DOTFILES_CONFLICT_POLICY=skip \
    DOTFILES_LOG_FILE="$failure_home/bootstrap-recovered.log" \
    "$INSTALL" --source "$lifecycle_source" --sections detect --yes --no-doctor 2>&1
)"
recovery_status=$?
set -e
[[ "$recovery_status" -eq 0 ]] || {
  printf 'bootstrap recovery failed (exit %s)\n%s\n' \
    "$recovery_status" "$recovery_output" >&2
  exit 1
}
grep -Fq 'Bootstrap Complete' <<<"$recovery_output"
assert_no_lock_ipc "$failure_state"

printf 'Bootstrap lock test passed\n'
