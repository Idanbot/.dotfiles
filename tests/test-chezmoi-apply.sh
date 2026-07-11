#!/usr/bin/env bash
# test-chezmoi-apply.sh — Render/apply chezmoi into a temporary HOME
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT=$(mktemp -d)
TMP_SOURCE="$TMP_ROOT/source"
trap 'rm -rf "$TMP_ROOT"' EXIT

if ! command -v chezmoi >/dev/null 2>&1; then
  echo "chezmoi not installed; skipping chezmoi apply fixture"
  exit 0
fi

mkdir -p "$TMP_SOURCE"
tar -C "$DOTFILES_DIR" \
  --exclude=.git \
  --exclude=.chezmoiexternal.yaml \
  -cf - . | tar -C "$TMP_SOURCE" -xf -

run_fixture() {
  local profile="$1"
  local is_wsl="$2"
  local expected_history='fixture-history-must-survive'
  local expected_overlay='export FIXTURE_LOCAL=preserved'

  export HOME="$TMP_ROOT/home-$profile"
  export DOTFILES_WSL="$is_wsl"
  mkdir -p "$HOME/.config/chezmoi" "$HOME/.config/dotfiles"

  printf '%s\n' "$expected_history" >"$HOME/.zsh_history"
  printf '%s\n' "$expected_overlay" >"$HOME/.config/dotfiles/local.zsh"
  chmod 600 "$HOME/.zsh_history" "$HOME/.config/dotfiles/local.zsh"

  cat >"$HOME/.config/chezmoi/chezmoi.yaml" <<EOF
data:
  name: "Test User"
  email: "test@example.com"
  sessionizer_dirs: "~/Code ~/Scripts"
  is_wsl: $is_wsl
EOF

  chezmoi init --source="$TMP_SOURCE" \
    --promptString="Full name=Test User" \
    --promptString="Git email=test@example.com" \
    --promptString="tmux-sessionizer search dirs (space-separated)=~/Code ~/Scripts"
  chezmoi apply --source="$TMP_SOURCE" --destination="$HOME" --force --exclude=scripts,externals

  test -f "$HOME/.zshrc"
  test -f "$HOME/.tmux.conf"
  test -f "$HOME/.gitconfig"
  test "$(cat "$HOME/.zsh_history")" = "$expected_history"
  test "$(cat "$HOME/.config/dotfiles/local.zsh")" = "$expected_overlay"
  test "$(stat -c '%a' "$HOME/.zsh_history")" = 600
  test "$(stat -c '%a' "$HOME/.config/dotfiles/local.zsh")" = 600

  if [[ "$is_wsl" == true ]]; then
    test ! -e "$HOME/.config/kitty"
  else
    test -f "$HOME/.config/kitty/kitty.conf"
  fi

  echo "chezmoi apply fixture passed ($profile)"
}

run_fixture native false
run_fixture wsl true
