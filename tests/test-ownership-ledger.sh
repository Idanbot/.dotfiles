#!/usr/bin/env bash
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
printf 'one\n' >"$HOME/.local/bin/demo"
record_install demo 1.0 test "$HOME/.local/bin/demo"
record_install demo 1.1 test "$HOME/.local/bin/demo"
[[ "$(wc -l <"$DOTFILES_STATE_DIR/installed.tsv")" -eq 1 ]]
grep -Fq $'demo\t1.1\ttest' "$DOTFILES_STATE_DIR/installed.tsv"
[[ "$(stat -c '%a' "$DOTFILES_STATE_DIR/installed.tsv")" == 600 ]]

"$DOTFILES_DIR/scripts/uninstall-tool.sh" --dry-run demo | grep -Fq 'would remove'
"$DOTFILES_DIR/scripts/uninstall-tool.sh" demo >/dev/null
[[ ! -e "$HOME/.local/bin/demo" ]]
! grep -q '^demo' "$DOTFILES_STATE_DIR/installed.tsv"

printf 'Ownership ledger test passed\n'
