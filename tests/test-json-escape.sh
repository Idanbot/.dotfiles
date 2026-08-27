#!/usr/bin/env bash
# Verify log payloads remain valid JSON when messages contain control characters.

set -euo pipefail

DOTFILES_DIR=""
if [[ $# -gt 0 ]]; then
  DOTFILES_DIR="$1"
fi
if [[ -z "$DOTFILES_DIR" ]]; then
  DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fi
export DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

value=$'quote " slash \\ newline\n tab\t carriage\r backspace\b formfeed\f'
escaped="$(json_escape "$value")"

[[ "$escaped" == *'\n'* ]]
[[ "$escaped" == *'\t'* ]]
[[ "$escaped" == *'\r'* ]]
[[ "$escaped" == *'\b'* ]]
[[ "$escaped" == *'\f'* ]]
json="$(printf '{"message":"%s"}\n' "$escaped")"
printf '%s\n' "$json" | jq -e --arg expected "$value" '.message == $expected' >/dev/null

printf 'JSON escaping test passed\n'
