#!/usr/bin/env bash
# generate-keybinding-docs.sh — Build docs/keybindings.md from terminal and shell configs
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUTPUT_FILE="${1:-$DOTFILES_DIR/docs/keybindings.md}"
TMUX_FILE="$DOTFILES_DIR/dot_tmux.conf.tmpl"
KITTY_FILE="$DOTFILES_DIR/dot_config/private_kitty/kitty.conf.tmpl"
ZSH_FILE="$DOTFILES_DIR/dot_zshrc.tmpl"

mkdir -p "$(dirname "$OUTPUT_FILE")"

{
  echo "# Keybindings"
  echo
  echo "Generated from tmux, Kitty, and zsh config. Regenerate with:"
  echo
  echo '```bash'
  echo './scripts/generate-keybinding-docs.sh'
  echo '```'
  echo
  echo "## tmux"
  echo
  echo "| Key | Action |"
  echo "|-----|--------|"
  awk '
    /^[[:space:]]*bind-key/ || /^[[:space:]]*bind / {
      line = $0
      gsub(/\r$/, "", line)
      global = line ~ /^[[:space:]]*(bind-key|bind)[[:space:]]+-n[[:space:]]+/
      key = line
      sub(/^[[:space:]]*bind-key[[:space:]]+(-[A-Za-z][[:space:]]+)*/, "", key)
      sub(/^[[:space:]]*bind[[:space:]]+(-[A-Za-z][[:space:]]+)*/, "", key)
      action = key
      sub(/[[:space:]].*$/, "", key)
      sub(/^[^[:space:]]+[[:space:]]+/, "", action)
      if (!global) key = "prefix+" key
      gsub(/\|/, "\\|", key)
      gsub(/\|/, "\\|", action)
      printf "| %s | `%s` |\n", key, action
    }
  ' "$TMUX_FILE"
  echo
  echo "## Kitty"
  echo
  echo "| Key | Action |"
  echo "|-----|--------|"
  awk '
    /^[[:space:]]*map[[:space:]]+/ {
      key = $2
      action = $0
      sub(/^[[:space:]]*map[[:space:]]+[^[:space:]]+[[:space:]]+/, "", action)
      gsub(/\|/, "\\|", key)
      gsub(/\|/, "\\|", action)
      printf "| %s | `%s` |\n", key, action
    }
  ' "$KITTY_FILE"
  echo
  echo "## zsh aliases"
  echo
  echo "| Alias | Command |"
  echo "|-------|---------|"
  awk '
    /^[[:space:]]*alias[[:space:]]+[A-Za-z0-9_-]+=/ {
      line = $0
      sub(/^[[:space:]]*alias[[:space:]]+/, "", line)
      name = line
      sub(/=.*/, "", name)
      command = line
      sub(/^[^=]+=/, "", command)
      gsub(/^\047|\047$/, "", command)
      gsub(/\|/, "\\|", command)
      printf "| %s | `%s` |\n", name, command
    }
  ' "$ZSH_FILE"
} >"$OUTPUT_FILE"
