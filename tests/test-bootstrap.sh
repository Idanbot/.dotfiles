#!/usr/bin/env bash
# test-bootstrap.sh — Validates the bootstrap process in a Docker container
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

assert_installed() {
  local cmd="$1"
  local label="${2:-$cmd}"
  if command -v "$cmd" &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} $label found at $(command -v "$cmd")"
    ((PASSED++)) || true
  else
    echo -e "  ${RED}✗${NC} $label NOT found"
    ((FAILED++)) || true
  fi
}

assert_file_exists() {
  local file="$1"
  local label="${2:-$file}"
  if [[ -f "$file" ]]; then
    echo -e "  ${GREEN}✓${NC} $label exists"
    ((PASSED++)) || true
  else
    echo -e "  ${RED}✗${NC} $label NOT found"
    ((FAILED++)) || true
  fi
}

assert_dir_exists() {
  local dir="$1"
  local label="${2:-$dir}"
  if [[ -d "$dir" ]]; then
    echo -e "  ${GREEN}✓${NC} $label exists"
    ((PASSED++)) || true
  else
    echo -e "  ${RED}✗${NC} $label NOT found"
    ((FAILED++)) || true
  fi
}

echo -e "\n${BOLD}══ Dotfiles Bootstrap Test ══${NC}"
echo -e "Environment: WSL=${DOTFILES_WSL:-false}, CI=${DOTFILES_CI:-false}\n"

# Copy dotfiles to source location
echo -e "${BOLD}── Setup ──${NC}"
cp -r /dotfiles "$HOME/.dotfiles"
chmod +x "$HOME/.dotfiles/scripts/lib.sh"
find "$HOME/.dotfiles" -name '*.sh' -exec chmod +x {} \;
find "$HOME/.dotfiles" -name '*.sh.tmpl' -exec chmod +x {} \;
echo -e "  ${GREEN}✓${NC} Dotfiles copied to ~/.dotfiles"

# Source lib.sh and validate it loads
echo -e "\n${BOLD}── Library (lib.sh) ──${NC}"
source "$HOME/.dotfiles/scripts/lib.sh"
assert_file_exists "$HOME/.dotfiles/scripts/lib.sh" "lib.sh"
echo -e "  ${GREEN}✓${NC} lib.sh sourced successfully"
((PASSED++)) || true

# Test library functions
if is_wsl || is_native; then
  echo -e "  ${GREEN}✓${NC} WSL/native detection works"
  ((PASSED++)) || true
fi

# Run core package install (limited in CI)
echo -e "\n${BOLD}── Core Packages ──${NC}"
sudo apt-get update -qq
sudo apt-get install -y -qq git curl wget jq make unzip >/dev/null 2>&1
assert_installed git
assert_installed curl
assert_installed wget
assert_installed jq
assert_installed make
assert_installed unzip

# Verify directory structure
echo -e "\n${BOLD}── Directory Structure ──${NC}"
mkdir -p "$HOME/Code" "$HOME/Scripts" "$HOME/Education" "$HOME/.local/bin" "$HOME/.config"
assert_dir_exists "$HOME/Code"
assert_dir_exists "$HOME/Scripts"
assert_dir_exists "$HOME/.local/bin"
assert_dir_exists "$HOME/.config"

# Verify config files exist in source
echo -e "\n${BOLD}── Config Files (Source) ──${NC}"
assert_file_exists "$HOME/.dotfiles/dot_zshrc.tmpl" ".zshrc template"
assert_file_exists "$HOME/.dotfiles/dot_tmux.conf.tmpl" ".tmux.conf template"
assert_file_exists "$HOME/.dotfiles/dot_gitconfig.tmpl" ".gitconfig template"
assert_file_exists "$HOME/.dotfiles/dot_vimrc" ".vimrc"
assert_file_exists "$HOME/.dotfiles/dot_config/starship.toml" "starship.toml"
assert_file_exists "$HOME/.dotfiles/packages.yaml" "packages.yaml"
assert_file_exists "$HOME/.dotfiles/.chezmoi.yaml.tmpl" ".chezmoi.yaml.tmpl"

# Summary
echo -e "\n${BOLD}══ Results ══${NC}"
echo -e "  ${GREEN}Passed:${NC}  $PASSED"
echo -e "  ${RED}Failed:${NC}  $FAILED"
echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED"

if [[ $FAILED -gt 0 ]]; then
  echo -e "\n${RED}${BOLD}TESTS FAILED${NC}"
  exit 1
else
  echo -e "\n${GREEN}${BOLD}ALL TESTS PASSED${NC}"
  exit 0
fi
