#!/usr/bin/env bash
# install.sh — Minimal bootstrap for a fresh Ubuntu 24.04 (native or WSL)
# Usage: curl -fsSL https://raw.githubusercontent.com/Idanbot/.dotfiles/main/scripts/install.sh | bash
# Or:    git clone https://github.com/Idanbot/.dotfiles.git ~/.dotfiles && ~/.dotfiles/scripts/install.sh

set -euo pipefail

if [[ "${1:-}" == "--only" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "Usage: ./scripts/install.sh --only <section>" >&2
    exit 1
  fi
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-section.sh" "$2"
fi

DOTFILES_REPO_URL="${DOTFILES_REPO_URL:-https://github.com/Idanbot/.dotfiles.git}"
SCRIPT_DIR=""
LOCAL_SOURCE=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/../.chezmoi.yaml.tmpl" ]]; then
    LOCAL_SOURCE="$(cd "$SCRIPT_DIR/.." && pwd)"
  fi
fi

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

CHEZMOI_INIT_ARGS=()
DOTFILES_GIT_NAME="${DOTFILES_GIT_NAME:-$(git config --global user.name 2>/dev/null || true)}"
DOTFILES_GIT_EMAIL="${DOTFILES_GIT_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"
if [[ -n "$DOTFILES_GIT_NAME" ]]; then
  CHEZMOI_INIT_ARGS+=(--promptString="Full name=$DOTFILES_GIT_NAME")
fi
if [[ -n "$DOTFILES_GIT_EMAIL" ]]; then
  CHEZMOI_INIT_ARGS+=(--promptString="Git email=$DOTFILES_GIT_EMAIL")
fi

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

APPLY_EXCLUDES=()

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
    echo "[IMPORTANT] Encrypted secrets will be skipped until they are re-encrypted for this new key."
    echo
    APPLY_EXCLUDES+=(encrypted)
  fi
fi

# Initialize and apply chezmoi
echo "[INFO] Initializing chezmoi..."
if [[ -n "$LOCAL_SOURCE" ]]; then
  echo "[INFO] Using local source: $LOCAL_SOURCE"
  chezmoi init --source="$LOCAL_SOURCE" "${CHEZMOI_INIT_ARGS[@]}"
else
  echo "[INFO] Cloning source over HTTPS: $DOTFILES_REPO_URL"
  chezmoi init "$DOTFILES_REPO_URL" "${CHEZMOI_INIT_ARGS[@]}"
fi

echo "[INFO] Applying dotfiles..."
if [[ ${#APPLY_EXCLUDES[@]} -gt 0 ]]; then
  exclude_csv=$(IFS=,; echo "${APPLY_EXCLUDES[*]}")
  chezmoi apply --exclude="$exclude_csv"
else
  chezmoi apply
fi

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
