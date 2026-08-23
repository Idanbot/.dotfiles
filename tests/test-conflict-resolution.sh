#!/usr/bin/env bash
# Verify conflict previews, decisions, and append-merge behavior.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
mkdir -p "$HOME" "$TMP_ROOT/bin" "$TMP_ROOT/source"
export PATH="$TMP_ROOT/bin:$PATH"
export FAKE_MANAGED='export MANAGED=1
printf "%s\\n" managed'

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  '  cat) printf "%b\\n" "$FAKE_MANAGED" ;;' \
  '  diff) printf "%s\\n" "- password=super-secret" "+ password=[managed]"; exit 1 ;;' \
  '  apply) printf "%s\\n" "$*" >>"${APPLY_LOG:-/dev/null}" ;;' \
  '  *) exit 0 ;;' \
  'esac' >"$TMP_ROOT/bin/chezmoi"
chmod 755 "$TMP_ROOT/bin/chezmoi"

log_info() { printf 'INFO %s\n' "$*"; }
log_warn() { printf 'WARN %s\n' "$*"; }
log_error() { printf 'ERROR %s\n' "$*" >&2; }

CHOICE=""
read_user() {
  local _prompt="$1" destination="$2"
  printf -v "$destination" '%s' "$CHOICE"
}

# shellcheck source=../scripts/conflicts.sh
source "$DOTFILES_DIR/scripts/conflicts.sh"

[[ "$(dotfiles_conflict_status_path 'MM .zshrc')" == .zshrc ]]
touch "$HOME/.zshrc"
dotfiles_conflict_destination_modified 'MM .zshrc'

diff_output="$(dotfiles_conflict_diff "$TMP_ROOT/source" .zshrc 20)"
grep -Fq 'password=[REDACTED]' <<<"$diff_output"
! grep -Fq super-secret <<<"$diff_output"

export CONFLICT_AUTO_APPROVE=false
CHOICE=s
dotfiles_conflict_prompt "$TMP_ROOT/source" .zshrc
[[ "$DOTFILES_CONFLICT_ACTION" == skip ]]
CHOICE=r
dotfiles_conflict_prompt "$TMP_ROOT/source" .zshrc
[[ "$DOTFILES_CONFLICT_ACTION" == replace ]]
CHOICE=m
dotfiles_conflict_prompt "$TMP_ROOT/source" .zshrc
[[ "$DOTFILES_CONFLICT_ACTION" == merge ]]
CHOICE=a
dotfiles_conflict_prompt "$TMP_ROOT/source" .zshrc
[[ "$DOTFILES_CONFLICT_ACTION" == replace-all ]]
CHOICE=k
dotfiles_conflict_prompt "$TMP_ROOT/source" .zshrc
[[ "$DOTFILES_CONFLICT_ACTION" == skip-all ]]
CHOICE=q
dotfiles_conflict_prompt "$TMP_ROOT/source" .zshrc
[[ "$DOTFILES_CONFLICT_ACTION" == quit ]]
CONFLICT_AUTO_APPROVE=true
dotfiles_conflict_prompt "$TMP_ROOT/source" .zshrc
[[ "$DOTFILES_CONFLICT_ACTION" == replace ]]

CONFLICT_AUTO_APPROVE=false
printf '%s\n' 'export LOCAL=1' >"$HOME/.zshrc"
chmod 640 "$HOME/.zshrc"
dotfiles_conflict_merge_append "$TMP_ROOT/source" .zshrc
grep -Fq 'export MANAGED=1' "$HOME/.zshrc"
grep -Fq 'export LOCAL=1' "$HOME/.zshrc"
[[ "$(stat -c '%a' "$HOME/.zshrc")" == 640 ]]
merged_once="$(sha256sum "$HOME/.zshrc")"
if dotfiles_conflict_merge_append "$TMP_ROOT/source" .zshrc; then
  printf 'expected an already-merged result\n' >&2
  exit 1
else
  [[ "$?" -eq 3 ]]
fi
[[ "$merged_once" == "$(sha256sum "$HOME/.zshrc")" ]]

export FAKE_MANAGED='export MANAGED=2'
dotfiles_conflict_merge_append "$TMP_ROOT/source" .zshrc
grep -Fq 'export MANAGED=2' "$HOME/.zshrc"
[[ "$(grep -Fc 'export LOCAL=1' "$HOME/.zshrc")" -eq 1 ]]

printf '%s\n' '{"local":true}' >"$HOME/settings.json"
before_json="$(sha256sum "$HOME/settings.json")"
if dotfiles_conflict_merge_append "$TMP_ROOT/source" settings.json; then
  printf 'json append merge should be unsupported\n' >&2
  exit 1
else
  [[ "$?" -eq 2 ]]
fi
[[ "$before_json" == "$(sha256sum "$HOME/settings.json")" ]]

mkdir -p "$HOME/.config"
export APPLY_LOG="$TMP_ROOT/apply.log"
: >"$APPLY_LOG"
export CHEZMOI_SOURCE="$TMP_ROOT/source"
export CHEZMOI_STATUS_OUTPUT=$'MM .zshrc\nMM .config\n M .config/other.conf'
CONFLICT_AUTO_APPROVE=true
dotfiles_apply_selected_conflicts
grep -Fq -- '--force .zshrc .config/other.conf' "$APPLY_LOG"
! grep -Fq -- '--force .config' "$APPLY_LOG"
grep -Fq -- '--include=dirs,externals --force' "$APPLY_LOG"

printf 'Conflict resolution test passed\n'
