#!/usr/bin/env bash
# run-section.sh — Render and run one install section from the local chezmoi source
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SECTION="${1:-}"

usage() {
  cat <<'USAGE'
Usage: scripts/run-section.sh <section>

Sections:
  detect       environment and directory setup
  core         core apt packages
  zsh          zsh and shell ecosystem
  terminal     terminal CLI tools
  languages    Go, Rust, Node.js, TypeScript, Python, Java
  history      optional Atuin installation (activation remains local/manual)
  cloud        Docker, kubectl, Helm, Terraform, cloud CLIs
  tmux         tmux, tmuxp, and Herdr
  neovim       Neovim
  ai           AI CLIs
  media        media tools
  fonts        Nerd Fonts
  desktop      native desktop tools
  system       system configuration
  theme        Catppuccin theme assets
  vscode       VS Code extensions
  services     user services
USAGE
}

if [[ -z "$SECTION" || "$SECTION" == "-h" || "$SECTION" == "--help" ]]; then
  usage
  exit 0
fi

exec "$DOTFILES_DIR/scripts/install.sh" --source "$DOTFILES_DIR" --only "$SECTION"
