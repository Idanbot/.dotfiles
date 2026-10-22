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

# The installer library adds fallbacks without reselecting an incoming command.
export HOME="$temporary/installer-home" DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
export DOTFILES_STATE_DIR="$HOME/state" DOTFILES_NPM_PREFIX="$HOME/custom-npm"
mkdir -p "$HOME/external/bin" "$HOME/.local/bin" "$DOTFILES_NPM_PREFIX/bin" \
  "$HOME/.cargo/bin" "$HOME/.fzf/bin"
for directory in "$HOME/external/bin" "$HOME/.local/bin" \
  "$DOTFILES_NPM_PREFIX/bin" "$HOME/.cargo/bin" "$HOME/.fzf/bin"; do
  printf '#!/bin/sh\necho "%s"\n' "$directory" >"$directory/path-fixture"
  chmod +x "$directory/path-fixture"
done
for preferred in "$HOME/external/bin" "$HOME/.local/bin"; do
  (
    export PATH="$preferred:$HOME/external/bin:$HOME/.local/bin:/usr/bin:/bin"
    source "$DOTFILES_DIR/scripts/lib.sh"
    [[ "$(command -v path-fixture)" == "$preferred/path-fixture" ]]
    activate_node_paths
    source "$DOTFILES_DIR/scripts/lib.sh"
    [[ "$(command -v path-fixture)" == "$preferred/path-fixture" ]]
    [[ ":$PATH:" == *":$DOTFILES_NPM_PREFIX/bin:"* ]]
    before="$PATH"
    activate_node_paths
    [[ "$PATH" == "$before" ]]
  )
done
(
  export HOME="$temporary/fresh-installer-home"
  export DOTFILES_STATE_DIR="$HOME/state" DOTFILES_NPM_PREFIX="$HOME/custom-npm"
  export PATH=/usr/bin:/bin
  [[ ! -d "$HOME/.local/bin" ]]
  source "$DOTFILES_DIR/scripts/lib.sh"
  # Populate fallbacks only after activation, as on a fresh installation.
  for directory in "$HOME/.local/bin" "$DOTFILES_NPM_PREFIX/bin" \
    "$HOME/.cargo/bin" "$HOME/.fzf/bin"; do
    mkdir -p "$directory"
    printf '#!/bin/sh\necho fresh\n' >"$directory/fresh-command"
    chmod +x "$directory/fresh-command"
    [[ "$(fresh-command)" == fresh ]]
    [[ "$(command -v fresh-command)" == "$directory/fresh-command" ]]
    rm "$directory/fresh-command"
  done
  # Deliberate managed activation must remain ahead of the fallbacks.
  mkdir -p "$HOME/new-runtime/bin"
  export PATH="$HOME/new-runtime/bin:$PATH"
  printf '#!/bin/sh\necho deliberate\n' >"$HOME/new-runtime/bin/path-fixture"
  chmod +x "$HOME/new-runtime/bin/path-fixture"
  activate_node_paths
  [[ "$(path-fixture)" == deliberate ]]
)
printf 'Shell PATH and optional mise tests passed\n'
