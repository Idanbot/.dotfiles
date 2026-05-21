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
  cloud        Docker, kubectl, Helm, Terraform, cloud CLIs
  tmux         tmux and tmuxp
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

if ! command -v chezmoi >/dev/null 2>&1; then
  echo "chezmoi is required to render section templates" >&2
  exit 1
fi

declare -A SECTIONS=(
  [detect]=".chezmoiscripts/run_once_before_00-detect-environment.sh.tmpl"
  [core]=".chezmoiscripts/run_once_before_01-install-core-packages.sh.tmpl"
  [zsh]=".chezmoiscripts/run_once_before_02-install-zsh-ecosystem.sh.tmpl"
  [terminal]=".chezmoiscripts/run_once_before_03-install-terminal-tools.sh.tmpl"
  [languages]=".chezmoiscripts/run_once_04-install-languages.sh.tmpl"
  [cloud]=".chezmoiscripts/run_once_05-install-containers-cloud.sh.tmpl"
  [tmux]=".chezmoiscripts/run_once_06-install-tmux-ecosystem.sh.tmpl"
  [neovim]=".chezmoiscripts/run_once_07-install-neovim.sh.tmpl"
  [ai]=".chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl"
  [media]=".chezmoiscripts/run_once_09-install-media-tools.sh.tmpl"
  [fonts]=".chezmoiscripts/run_once_10-install-fonts.sh.tmpl"
  [desktop]=".chezmoiscripts/run_once_11-install-desktop.sh.tmpl"
  [system]=".chezmoiscripts/run_once_12-configure-system.sh.tmpl"
  [theme]=".chezmoiscripts/run_once_13-apply-catppuccin-theme.sh.tmpl"
  [vscode]=".chezmoiscripts/run_once_14-install-vscode-extensions.sh.tmpl"
  [services]=".chezmoiscripts/run_once_after_enable-services.sh.tmpl"
)

script="${SECTIONS[$SECTION]:-}"
if [[ -z "$script" ]]; then
  echo "Unknown section: $SECTION" >&2
  usage >&2
  exit 1
fi

script_path="$DOTFILES_DIR/$script"
if [[ ! -f "$script_path" ]]; then
  echo "Missing section script: $script_path" >&2
  exit 1
fi

chezmoi execute-template <"$script_path" | bash
