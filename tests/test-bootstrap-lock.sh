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

printf 'Bootstrap lock test passed\n'
