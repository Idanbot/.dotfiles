#!/usr/bin/env bash
# test-chezmoi-apply.sh — Render/apply chezmoi into a temporary HOME
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT=$(mktemp -d)
TMP_HOME="$TMP_ROOT/home"
TMP_SOURCE="$TMP_ROOT/source"
trap 'rm -rf "$TMP_ROOT"' EXIT

if ! command -v chezmoi >/dev/null 2>&1; then
  echo "chezmoi not installed; skipping chezmoi apply fixture"
  exit 0
fi

mkdir -p "$TMP_HOME" "$TMP_SOURCE"
tar -C "$DOTFILES_DIR" \
  --exclude=.git \
  --exclude=.chezmoiexternal.yaml \
  -cf - . | tar -C "$TMP_SOURCE" -xf -

export HOME="$TMP_HOME"
mkdir -p "$HOME/.config/chezmoi"

cat >"$HOME/.config/chezmoi/chezmoi.yaml" <<EOF
data:
  name: "Test User"
  email: "test@example.com"
  sessionizer_dirs: "~/Code ~/Scripts"
  is_wsl: false
EOF

chezmoi init --source="$TMP_SOURCE" --promptString="Full name=Test User" --promptString="Git email=test@example.com" --promptString="tmux-sessionizer search dirs (space-separated)=~/Code ~/Scripts"
chezmoi apply --source="$TMP_SOURCE" --destination="$HOME" --force --exclude=scripts,externals

test -f "$HOME/.zshrc"
test -f "$HOME/.tmux.conf"
test -f "$HOME/.gitconfig"

echo "chezmoi apply fixture passed"
