#!/usr/bin/env bash
# Fast helper idempotency checks. CI's base/full E2E runs install.sh twice.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
export DOTFILES_STATE_DIR="$HOME/state"
export DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

mkdir -p "$HOME/.local/bin"
printf 'demo\n' >"$HOME/.local/bin/demo"
record_install demo 1.0 test "$HOME/.local/bin/demo"
record_install demo 1.0 test "$HOME/.local/bin/demo"
[[ "$(wc -l <"$DOTFILES_STATE_DIR/installed.tsv")" -eq 1 ]]

first="$(section_manifest_hash languages)"
second="$(section_manifest_hash languages)"
[[ "$first" == "$second" ]]

printf 'Helper idempotency test passed; installer idempotency is Docker E2E\n'
