#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/Code/alpha" "$HOME/Scripts/beta"
rendered="$HOME/tmux-sessionizer"
sed 's#{{ .sessionizer_dirs | quote }}#"~/Code ~/Scripts"#' \
  "$DOTFILES_DIR/dot_local/bin/executable_tmux-sessionizer.tmpl" >"$rendered"
chmod +x "$rendered"

[[ "$($rendered --print "$HOME/Code/alpha")" == "$HOME/Code/alpha" ]]
[[ "$($rendered -s 1 --print "$HOME/Scripts/beta")" == "$HOME/Scripts/beta" ]]
set +e
"$rendered" -s 9 --print >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]]
grep -Fq 'tmux-sessionizer -s 0' "$DOTFILES_DIR/dot_zshrc.tmpl"

printf 'Sessionizer test passed\n'
