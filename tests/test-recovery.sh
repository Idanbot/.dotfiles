#!/usr/bin/env bash
# Verify absent, modified, and newly-created paths restore transactionally.

set -euo pipefail

DOTFILES_DIR="${1:-/dotfiles}"
BACKUP="$DOTFILES_DIR/scripts/backup.sh"
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
export DOTFILES_STATE_DIR="$HOME/.local/state/dotfiles"

mkdir -p "$HOME/.config/example" "$HOME/.local/share/example"
printf 'original\n' >"$HOME/.zshrc"
printf 'nested\n' >"$HOME/.config/example/value"
ln -s ../value "$HOME/.config/example/link"
printf 'local original\n' >"$HOME/.local/share/example/value"
printf 'keep me\n' >"$HOME/.local/share/unmanaged"
chmod 600 "$HOME/.zshrc"
chmod 700 "$HOME/.local"

status_file="$HOME/status.txt"
printf 'MM .zshrc\nMM .config/example/value\nMM .config/example/link\n M .local\nMM .local/share/example/value\nAA .config/new.conf\n' >"$status_file"
output="$($BACKUP create --status-file "$status_file" --run-id test)"
backup_id="$(sed -n 's/^backup_id=//p' <<<"$output")"
[[ -n "$backup_id" ]]
[[ "$(stat -c '%a' "$DOTFILES_STATE_DIR")" == 700 ]]

printf 'changed\n' >"$HOME/.zshrc"
printf 'changed nested\n' >"$HOME/.config/example/value"
printf 'local changed\n' >"$HOME/.local/share/example/value"
printf 'new\n' >"$HOME/.config/new.conf"
chmod 755 "$HOME/.local"

"$DOTFILES_DIR/scripts/backup.sh" restore "$backup_id" --force >/dev/null
grep -Fxq original "$HOME/.zshrc"
grep -Fxq nested "$HOME/.config/example/value"
[[ -L "$HOME/.config/example/link" ]]
[[ "$(readlink "$HOME/.config/example/link")" == ../value ]]
grep -Fxq 'local original' "$HOME/.local/share/example/value"
grep -Fxq 'keep me' "$HOME/.local/share/unmanaged"
[[ "$(stat -c '%a' "$HOME/.local")" == 700 ]]
[[ ! -e "$HOME/.config/new.conf" ]]
[[ "$(stat -c '%a' "$HOME/.zshrc")" == 600 ]]
"$BACKUP" verify "$backup_id" >/dev/null
"$BACKUP" verify latest >/dev/null
if "$BACKUP" verify ../outside >/dev/null 2>&1; then
  printf 'unsafe backup id was accepted\n' >&2
  exit 1
fi
manifest="$DOTFILES_STATE_DIR/backups/$backup_id/manifest.tsv"
cp "$manifest" "$manifest.valid"
printf 'nested/..\tabsent\t-\t-\n' >>"$manifest"
if "$BACKUP" verify "$backup_id" >/dev/null 2>&1; then
  printf 'unsafe backup path was accepted\n' >&2
  exit 1
fi
mv "$manifest.valid" "$manifest"

printf 'changed after valid restore\n' >"$HOME/.zshrc"
backup_dir="$DOTFILES_STATE_DIR/backups/$backup_id"
printf 'tampered\n' >"$backup_dir/files/.zshrc"
set +e
tamper_output="$($BACKUP restore "$backup_id" --force 2>&1)"
tamper_status=$?
set -e
[[ "$tamper_status" -ne 0 ]]
grep -Fq 'Backup checksum failed: .zshrc' <<<"$tamper_output"
grep -Fxq 'changed after valid restore' "$HOME/.zshrc"
set +e
verify_status=0
"$BACKUP" verify "$backup_id" >/dev/null 2>&1 || verify_status=$?
set -e
[[ "$verify_status" -ne 0 ]]

"$BACKUP" list | grep -Fxq "$backup_id"

printf 'Recovery test passed: %s\n' "$backup_id"
