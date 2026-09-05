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
  '  cat) [[ "${CAT_FAILURE:-false}" == true ]] && exit 7; printf "%b\\n" "$FAKE_MANAGED" ;;' \
  '  diff) printf "%s\\n" "- password=super-secret" "+ password = spaced-secret"; for line in 1 2 3; do printf "%s\\n" "diff-$line"; done; exit 1 ;;' \
  '  apply) printf "%s\\n" "$*" >>"${APPLY_LOG:-/dev/null}"; if [[ "${APPLY_FAILURE:-false}" == true ]]; then exit 9; fi; exit 0 ;;' \
  '  *) exit 0 ;;' \
  'esac' >"$TMP_ROOT/bin/chezmoi"
chmod 755 "$TMP_ROOT/bin/chezmoi"

log_info() { printf 'INFO %s\n' "$*"; }
log_warn() { printf 'WARN %s\n' "$*"; }
log_error() { printf 'ERROR %s\n' "$*" >&2; }
log_skip() { printf 'SKIP %s\n' "$*"; }

CHOICE=""
CHOICE_QUEUE=()
read_user() {
  local _prompt="$1" destination="$2" selected_choice
  [[ "${READ_FAILURE:-false}" == true ]] && return 1
  if [[ ${#CHOICE_QUEUE[@]} -gt 0 ]]; then
    selected_choice="${CHOICE_QUEUE[0]}"
    CHOICE_QUEUE=("${CHOICE_QUEUE[@]:1}")
  else
    selected_choice="$CHOICE"
  fi
  printf -v "$destination" '%s' "$selected_choice"
}

# shellcheck source=../scripts/conflicts.sh
source "$DOTFILES_DIR/scripts/conflicts.sh"

mkdir -p "$HOME/.ssh"
printf 'Host review-host\n  ServerAliveInterval 5\n' >"$HOME/.ssh/config"
printf '[credential]\n  helper = local-helper\n' >"$HOME/.gitconfig"
for sensitive_format in .ssh/config .gitconfig; do
  original="$(sha256sum "$HOME/$sensitive_format")"
  if dotfiles_conflict_merge_append "$TMP_ROOT/source" "$sensitive_format"; then
    printf 'unsafe append allowed: %s\n' "$sensitive_format" >&2
    exit 1
  fi
  [[ "$original" == "$(sha256sum "$HOME/$sensitive_format")" ]]
done
CHOICE=y
EDITOR=true
export EDITOR
before_ssh="$(ssh -G -F "$HOME/.ssh/config" review-host 2>/dev/null)"
before_git="$(git config --file "$HOME/.gitconfig" --get-all credential.helper)"
dotfiles_conflict_review_merge "$TMP_ROOT/source" .ssh/config
dotfiles_conflict_review_merge "$TMP_ROOT/source" .gitconfig
[[ "$(ssh -G -F "$HOME/.ssh/config" review-host 2>/dev/null)" == "$before_ssh" ]]
[[ "$(git config --file "$HOME/.gitconfig" --get-all credential.helper)" == "$before_git" ]]

[[ "$(dotfiles_conflict_status_path 'MM .zshrc')" == .zshrc ]]
[[ "$(dotfiles_conflict_status_path $'MM .zshrc\r')" == .zshrc ]]
touch "$HOME/.zshrc"
dotfiles_conflict_destination_modified 'MM .zshrc'

diff_output="$(dotfiles_conflict_diff "$TMP_ROOT/source" .zshrc 20)"
grep -Fq 'password=[REDACTED]' <<<"$diff_output"
grep -Fq 'password = [REDACTED]' <<<"$diff_output"
! grep -Fq super-secret <<<"$diff_output"
! grep -Fq spaced-secret <<<"$diff_output"
limited_diff="$(dotfiles_conflict_diff "$TMP_ROOT/source" .zshrc 2)"
grep -Fq '... 3 more diff line(s)' <<<"$limited_diff"

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
CHOICE_QUEUE=(invalid d s)
dotfiles_conflict_prompt "$TMP_ROOT/source" .zshrc
[[ "$DOTFILES_CONFLICT_ACTION" == skip ]]
CONFLICT_AUTO_APPROVE=true
dotfiles_conflict_prompt "$TMP_ROOT/source" .zshrc
[[ "$DOTFILES_CONFLICT_ACTION" == replace ]]
CONFLICT_AUTO_APPROVE=false
READ_FAILURE=true
dotfiles_conflict_prompt "$TMP_ROOT/source" .zshrc
[[ "$DOTFILES_CONFLICT_ACTION" == quit ]]
unset READ_FAILURE

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

printf '%s\n' 'export LOCAL_AFTER=1' >>"$HOME/.zshrc"
export FAKE_MANAGED='export MANAGED=2'
dotfiles_conflict_merge_append "$TMP_ROOT/source" .zshrc
grep -Fq 'export MANAGED=2' "$HOME/.zshrc"
[[ "$(grep -Fc 'export LOCAL=1' "$HOME/.zshrc")" -eq 1 ]]
[[ "$(grep -Fc 'export LOCAL_AFTER=1' "$HOME/.zshrc")" -eq 1 ]]

before_cat_failure="$(sha256sum "$HOME/.zshrc")"
export CAT_FAILURE=true
if dotfiles_conflict_merge_append "$TMP_ROOT/source" .zshrc; then
  printf 'merge should fail when managed content cannot be rendered\n' >&2
  exit 1
else
  [[ "$?" -eq 1 ]]
fi
unset CAT_FAILURE
[[ "$before_cat_failure" == "$(sha256sum "$HOME/.zshrc")" ]]

FAKE_MANAGED='if broken syntax'
if dotfiles_conflict_merge_append "$TMP_ROOT/source" .zshrc; then
  printf 'invalid shell merge accepted\n' >&2
  exit 1
fi
[[ "$before_cat_failure" == "$(sha256sum "$HOME/.zshrc")" ]]
FAKE_MANAGED='export MANAGED=3'
mv() { return 37; }
if dotfiles_conflict_merge_append "$TMP_ROOT/source" .zshrc; then
  printf 'failed rename reported success\n' >&2
  exit 1
fi
unset -f mv
[[ "$before_cat_failure" == "$(sha256sum "$HOME/.zshrc")" ]]

printf '%s\n' '{"local":true}' >"$HOME/settings.json"
before_json="$(sha256sum "$HOME/settings.json")"
if dotfiles_conflict_merge_append "$TMP_ROOT/source" settings.json; then
  printf 'json append merge should be unsupported\n' >&2
  exit 1
else
  [[ "$?" -eq 2 ]]
fi
[[ "$before_json" == "$(sha256sum "$HOME/settings.json")" ]]

printf '%s\n' 'export REAL=1' >"$HOME/real.zsh"
real_before="$(sha256sum "$HOME/real.zsh")"
ln -s real.zsh "$HOME/link.zsh"
if dotfiles_conflict_merge_append "$TMP_ROOT/source" link.zsh; then
  printf 'symlink append merge should be unsupported\n' >&2
  exit 1
else
  [[ "$?" -eq 2 ]]
fi
! dotfiles_conflict_is_mergeable link.zsh
[[ "$real_before" == "$(sha256sum "$HOME/real.zsh")" ]]

mkdir -p "$HOME/.config"
! dotfiles_conflict_destination_modified 'MM .config'
! dotfiles_conflict_destination_modified 'AM missing.conf'
export APPLY_LOG="$TMP_ROOT/apply.log"
: >"$APPLY_LOG"
export CHEZMOI_SOURCE="$TMP_ROOT/source"
export CHEZMOI_STATUS_OUTPUT=$'MM .zshrc\nMM .config\n M .config/other.conf'
CONFLICT_AUTO_APPROVE=true
dotfiles_apply_selected_conflicts
grep -Fq -- '--force --no-tty .zshrc .config/other.conf' "$APPLY_LOG"
! grep -Fq -- '--force .config' "$APPLY_LOG"
grep -Fq -- '--include=dirs,externals --force --no-tty' "$APPLY_LOG"

export APPLY_FAILURE=true
if dotfiles_apply_selected_conflicts; then
  printf 'apply should propagate a chezmoi failure\n' >&2
  exit 1
else
  [[ "$?" -eq 1 ]]
fi
unset APPLY_FAILURE

read_user() {
  local _prompt="$1" destination="$2" selected_choice
  IFS= read -r selected_choice || return 1
  printf -v "$destination" '%s' "$selected_choice"
}
printf 's\ns\n' >"$TMP_ROOT/conflict-input"
export CHEZMOI_STATUS_OUTPUT=$'MM .zshrc\nMM .zshrc'
CONFLICT_AUTO_APPROVE=false
dotfiles_apply_selected_conflicts <"$TMP_ROOT/conflict-input"

printf 'Conflict resolution test passed\n'
