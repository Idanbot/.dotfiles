#!/usr/bin/env bash
# Verify absent, modified, and newly-created paths restore transactionally.

set -euo pipefail

DOTFILES_DIR="${1:-/dotfiles}"
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
export DOTFILES_STATE_DIR="$HOME/.local/state/dotfiles"

mkdir -p "$HOME/.config/example"
printf 'original\n' >"$HOME/.zshrc"
printf 'nested\n' >"$HOME/.config/example/value"
chmod 600 "$HOME/.zshrc"

status_file="$HOME/status.txt"
printf 'MM .zshrc\nMM .config/example/value\nAA .config/new.conf\n' >"$status_file"
output="$($DOTFILES_DIR/scripts/backup.sh create --status-file "$status_file" --run-id test)"
backup_id="$(sed -n 's/^backup_id=//p' <<<"$output")"
[[ -n "$backup_id" ]]

printf 'changed\n' >"$HOME/.zshrc"
printf 'changed nested\n' >"$HOME/.config/example/value"
printf 'new\n' >"$HOME/.config/new.conf"

"$DOTFILES_DIR/scripts/backup.sh" restore "$backup_id" --force >/dev/null
grep -Fxq original "$HOME/.zshrc"
grep -Fxq nested "$HOME/.config/example/value"
[[ ! -e "$HOME/.config/new.conf" ]]
[[ "$(stat -c '%a' "$HOME/.zshrc")" == 600 ]]
"$DOTFILES_DIR/scripts/backup.sh" list | grep -Fxq "$backup_id"

printf 'Recovery test passed: %s\n' "$backup_id"
