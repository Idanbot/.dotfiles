#!/usr/bin/env bash
# test-chezmoi-apply.sh — Render/apply chezmoi into a temporary HOME
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT

if ! command -v chezmoi >/dev/null 2>&1; then
  echo "chezmoi not installed; skipping chezmoi apply fixture"
  exit 0
fi

export HOME="$TMP_HOME"
mkdir -p "$HOME/.config/chezmoi"

cat >"$HOME/.config/chezmoi/chezmoi.yaml" <<EOF
data:
  name: "Test User"
  email: "test@example.com"
  sessionizer_dirs: "~/Code ~/Scripts"
  is_wsl: false
EOF

chezmoi init --source="$DOTFILES_DIR" --promptString="Full name=Test User" --promptString="Git email=test@example.com" --promptString="tmux-sessionizer search dirs (space-separated)=~/Code ~/Scripts"
chezmoi apply --source="$DOTFILES_DIR" --destination="$HOME" --force --exclude=scripts,externals

test -f "$HOME/.zshrc"
test -f "$HOME/.tmux.conf"
test -f "$HOME/.gitconfig"

echo "chezmoi apply fixture passed"
