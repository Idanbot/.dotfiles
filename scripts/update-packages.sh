#!/usr/bin/env bash
# scripts/update-packages.sh — Scans GitHub for updates to pinned package versions in packages.yaml
set -euo pipefail

# ANSI color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PACKAGES_FILE="$(dirname "$0")/../packages.yaml"

log_info() {
  echo -e "${CYAN}[INFO]${NC} $1"
}

log_upgrade() {
  echo -e "${GREEN}[UPDATE]${NC} $1: $2 -> $3"
}

log_uptodate() {
  echo -e "  $1 is up to date ($2)"
}

get_latest_github_release() {
  local repo="$1"
  # Fetch latest release tag, remove leading 'v'
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name' | sed 's/^v//'
}

update_package_version() {
  local tool_key="$1"
  local repo="$2"
  local current_version
  
  if [[ ! -f "$PACKAGES_FILE" ]]; then
    echo -e "${YELLOW}[WARN]${NC} Manifest file not found: $PACKAGES_FILE"
    return
  fi

  current_version=$(grep -E "^[[:space:]]*${tool_key}:" "$PACKAGES_FILE" | awk '{print $2}' | tr -d '"' | tr -d "'")

  if [[ -z "$current_version" || "$current_version" == "latest" || "$current_version" == "stable" ]]; then
    return
  fi

  local latest_version
  latest_version=$(get_latest_github_release "$repo")

  if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
    echo -e "${YELLOW}[WARN]${NC} Could not fetch latest release for $tool_key ($repo)"
    return
  fi

  if [[ "$current_version" != "$latest_version" ]]; then
    log_upgrade "$tool_key" "$current_version" "$latest_version"
    # Update the version in the packages.yaml file, replacing old version with quotes
    sed -i -E "s|^([[:space:]]*${tool_key}:[[:space:]]*)['\"]?${current_version}['\"]?|\1\"${latest_version}\"|g" "$PACKAGES_FILE"
  else
    log_uptodate "$tool_key" "$current_version"
  fi
}

log_info "Scanning pinned packages in packages.yaml..."

# Map tool keys in packages.yaml to their GitHub repositories
update_package_version "fzf" "junegunn/fzf"
update_package_version "fd" "sharkdp/fd"
update_package_version "ripgrep" "BurntSushi/ripgrep"
update_package_version "bat" "sharkdp/bat"
update_package_version "eza" "eza-community/eza"
update_package_version "lazygit" "jesseduffield/lazygit"
update_package_version "btop" "aristocratos/btop"
update_package_version "starship" "starship/starship"
update_package_version "neovim" "neovim/neovim"
update_package_version "helm" "helm/helm"
update_package_version "terraform" "hashicorp/terraform"
update_package_version "k9s" "derailed/k9s"
update_package_version "nerd_font_version" "ryanoasis/nerd-fonts"

log_info "Upgrade scan complete. If versions were updated, apply them using: chezmoi apply"
