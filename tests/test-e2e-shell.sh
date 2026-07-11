#!/usr/bin/env bash
# Validate the manual Docker E2E shell wrapper without starting Docker.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
WRAPPER="$DOTFILES_DIR/scripts/e2e-shell.sh"

assert_contains() {
  local description="$1"
  local output="$2"
  local expected="$3"
  grep -Fq -- "$expected" <<<"$output" || {
    printf 'missing %s: %s\noutput: %s\n' "$description" "$expected" "$output" >&2
    exit 1
  }
}

assert_fails() {
  local description="$1"
  shift
  if "$WRAPPER" "$@" >/dev/null 2>&1; then
    printf 'expected failure: %s\n' "$description" >&2
    exit 1
  fi
}

default_command="$($WRAPPER --print-command)"
assert_contains "default full profile" "$default_command" "E2E_PROFILE=full"
assert_contains "default native platform" "$default_command" "DOTFILES_WSL=false"
assert_contains "default single pass" "$default_command" "E2E_PASSES=1"
assert_contains "default image build" "$default_command" "--build"
assert_contains "ephemeral container" "$default_command" "--rm"

custom_command="$($WRAPPER --profile agent --platform wsl --passes 2 --no-build --print-command)"
assert_contains "custom agent profile" "$custom_command" "E2E_PROFILE=agent"
assert_contains "simulated WSL platform" "$custom_command" "DOTFILES_WSL=true"
assert_contains "custom pass count" "$custom_command" "E2E_PASSES=2"
if grep -Eq '(^|[[:space:]])--build([[:space:]]|$)' <<<"$custom_command"; then
  printf 'no-build command still contains --build: %s\n' "$custom_command" >&2
  exit 1
fi

assert_fails "unknown profile" --profile unknown --print-command
assert_fails "unknown platform" --platform windows --print-command
assert_fails "zero passes" --passes 0 --print-command
assert_fails "missing option value" --profile

"$WRAPPER" --help | grep -Fq 'DOTFILES_E2E_STATUS'

printf 'Manual Docker E2E shell wrapper test passed\n'
