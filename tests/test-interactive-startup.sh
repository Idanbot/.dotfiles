#!/usr/bin/env bash
# test-interactive-startup.sh — Smoke-test zsh and tmux startup parsing
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT

render_template() {
  local src="$1" dest="$2" is_wsl="${3:-false}"
  awk -v is_wsl="$is_wsl" -v source_dir="$DOTFILES_DIR" '
    function emit(line) {
      gsub(/{{ \.chezmoi\.sourceDir }}/, source_dir, line)
      gsub(/{{ \.chezmoi\.sourceFile }}/, source_dir, line)
      gsub(/{{ \.sessionizer_dirs }}/, "~/Code ~/Scripts", line)
      gsub(/{{ \.email }}/, "test@example.com", line)
      gsub(/{{ \.name }}/, "Test User", line)
      print line
    }
    /^[[:space:]]*{{-? if \.is_wsl }}[[:space:]]*$/ { stack[++depth] = include; include = include && (is_wsl == "true"); next }
    /^[[:space:]]*{{ if not \.is_wsl }}[[:space:]]*$/ { stack[++depth] = include; include = include && (is_wsl != "true"); next }
    /^[[:space:]]*{{-? else }}[[:space:]]*$/ { parent = stack[depth]; include = parent && !include; next }
    /^[[:space:]]*{{-? end }}[[:space:]]*$/ { include = stack[depth--]; next }
    BEGIN { include = 1; depth = 0 }
    { if (include) emit($0) }
  ' "$src" >"$dest"
}

mkdir -p "$TMP_HOME/.oh-my-zsh"
printf '# test stub
' >"$TMP_HOME/.oh-my-zsh/oh-my-zsh.sh"
cat >"$TMP_HOME/.zshenv" <<'EOF'
complete() { true; }
EOF

render_template "$DOTFILES_DIR/dot_zshrc.tmpl" "$TMP_HOME/.zshrc" false
render_template "$DOTFILES_DIR/dot_tmux.conf.tmpl" "$TMP_HOME/.tmux.conf" false

if command -v zsh >/dev/null 2>&1; then
  HOME="$TMP_HOME" ZDOTDIR="$TMP_HOME" zsh -i -c 'true'
else
  echo "zsh not installed; skipping zsh startup"
fi

if command -v tmux >/dev/null 2>&1; then
  tmux -L dotfiles-startup-test -f "$TMP_HOME/.tmux.conf" start-server \; source-file "$TMP_HOME/.tmux.conf" \; kill-server
else
  echo "tmux not installed; skipping tmux startup"
fi

echo "interactive startup smoke passed"
