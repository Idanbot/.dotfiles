#!/usr/bin/env bash
# Verify local runtime fallbacks without loading user configuration.
set -euo pipefail
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/home/.local/bin" "$temporary/home/.local/share/npm/bin"
awk '/^# Tool homes/ { block=1 } /^{{/ && block { exit } block' \
  "$DOTFILES_DIR/dot_zshrc.tmpl" >"$temporary/paths.zsh"
sed -n '/^# Support an existing standalone OpenCode/,/^typeset -U path PATH/p' \
  "$DOTFILES_DIR/dot_zshrc.tmpl" >>"$temporary/paths.zsh"
sed -n '/^if command -v mise /,/^fi$/p' \
  "$DOTFILES_DIR/dot_zshrc.tmpl" >"$temporary/mise.zsh"
printf '#!/bin/sh\nprintf "managed\\n"\n' >"$temporary/home/.local/share/npm/bin/opencode"
chmod +x "$temporary/home/.local/share/npm/bin/opencode"
HOME="$temporary/home" zsh -f -c '
  set -e
  source "$1/paths.zsh"
  [[ "$path" != *"$HOME/.opencode/bin"* ]]
  [[ "$(opencode)" == managed ]]
  mkdir -p "$HOME/.opencode/bin"
  printf "#!/bin/sh\necho standalone\n" >"$HOME/.opencode/bin/opencode"
  chmod +x "$HOME/.opencode/bin/opencode"
  source "$1/paths.zsh"
  source "$1/paths.zsh"
  [[ "$(opencode)" == managed ]]
  [[ ${(M)#path:#$HOME/.opencode/bin} == 1 ]]
  [[ ${(M)#path:#$HOME/bin} == 1 ]]
  rm "$HOME/.local/share/npm/bin/opencode"
  rehash
  [[ "$(opencode)" == standalone ]]
  path=(/usr/bin /bin)
  source "$1/mise.zsh"
  mise() {
    [[ "$*" == "activate zsh" ]] || return 1
    print "export MISE_TEST_ACTIVE=yes"
  }
  source "$1/mise.zsh"
  [[ "$MISE_TEST_ACTIVE" == yes ]]
' _ "$temporary"
printf 'Shell PATH and optional mise tests passed\n'
