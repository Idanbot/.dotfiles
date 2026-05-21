#!/usr/bin/env bash
# install.sh — Minimal bootstrap for a fresh Ubuntu 24.04 (native or WSL)
# Usage: curl -fsSL https://raw.githubusercontent.com/<user>/dotfiles/main/install.sh | bash
# Or:    git clone ... && ./install.sh

set -euo pipefail

echo "══════════════════════════════════════════════"
echo "  Dotfiles Bootstrap — Idan Botbol"
echo "══════════════════════════════════════════════"
echo

# Detect environment
if grep -qi microsoft /proc/version 2>/dev/null; then
  echo "[INFO] WSL environment detected"
else
  echo "[INFO] Native Linux environment detected"
fi

# Install prerequisites
echo "[INFO] Installing prerequisites (git, curl)..."
sudo apt-get update -qq
sudo apt-get install -y -qq git curl

# Install chezmoi
if ! command -v chezmoi &>/dev/null; then
  echo "[INFO] Installing chezmoi..."
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
  echo "[OK] chezmoi installed"
else
  echo "[SKIP] chezmoi already installed"
fi

# Install age for secret decryption
if ! command -v age &>/dev/null; then
  echo "[INFO] Installing age..."
  sudo apt-get install -y -qq age
  echo "[OK] age installed"
else
  echo "[SKIP] age already installed"
fi

# Check for age identity key
if [[ ! -f "$HOME/.config/chezmoi/key.txt" ]]; then
  echo
  echo "══════════════════════════════════════════════"
  echo "  Age Identity Key Required"
  echo "══════════════════════════════════════════════"
  echo
  echo "No age identity key found at ~/.config/chezmoi/key.txt"
  echo
  echo "Options:"
  echo "  1. Import existing key: Copy your backed-up key.txt to ~/.config/chezmoi/key.txt"
  echo "  2. Generate new key:    age-keygen -o ~/.config/chezmoi/key.txt"
  echo "     (Then update the recipient in .chezmoi.yaml and re-encrypt secrets)"
  echo
  read -rp "Do you have an existing key to import? [y/N] " response
  if [[ "$response" =~ ^[Yy]$ ]]; then
    echo "Please place your key at ~/.config/chezmoi/key.txt and re-run this script."
    exit 0
  else
    echo "[INFO] Generating new age identity key..."
    mkdir -p "$HOME/.config/chezmoi"
    age-keygen -o "$HOME/.config/chezmoi/key.txt" 2>&1 | tee /dev/stderr
    chmod 600 "$HOME/.config/chezmoi/key.txt"
    echo
    echo "[IMPORTANT] Back up ~/.config/chezmoi/key.txt to a safe location!"
    echo "[IMPORTANT] Update the 'recipient' field in .chezmoi.yaml with the public key above."
    echo
  fi
fi

# Initialize and apply chezmoi
echo "[INFO] Initializing chezmoi..."
GITHUB_USER="${GITHUB_USER:-idanbotbol}"
chezmoi init "$GITHUB_USER/dotfiles" --ssh

echo "[INFO] Applying dotfiles..."
chezmoi apply

echo
echo "══════════════════════════════════════════════"
echo "  Bootstrap Complete!"
echo "══════════════════════════════════════════════"
echo
echo "Next steps:"
echo "  1. Restart your shell: exec zsh"
echo "  2. tmux will auto-install plugins on first launch"
echo "  3. Neovim will bootstrap LazyVim on first launch"
echo
