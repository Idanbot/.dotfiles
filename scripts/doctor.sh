#!/usr/bin/env bash
# doctor.sh — Check dotfiles runtime health after bootstrap
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

CHECKS=0
FAILED_CHECKS=0

check_cmd() {
  local cmd="$1" label="${2:-$1}"
  ((CHECKS++)) || true
  if command -v "$cmd" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $label -> $(command -v "$cmd")"
  else
    echo -e "  ${RED}✗${NC} missing $label"
    ((FAILED_CHECKS++)) || true
  fi
}

check_optional_cmd() {
  local cmd="$1" label="${2:-$1}"
  ((CHECKS++)) || true
  if command -v "$cmd" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $label -> $(command -v "$cmd")"
  else
    echo -e "  ${YELLOW}⚠${NC} optional $label not found"
  fi
}

check_file() {
  local file="$1" label="${2:-$1}"
  ((CHECKS++)) || true
  if [[ -e "$file" ]]; then
    echo -e "  ${GREEN}✓${NC} $label exists"
  else
    echo -e "  ${RED}✗${NC} missing $label"
    ((FAILED_CHECKS++)) || true
  fi
}

check_version() {
  local cmd="$1" expected="$2" actual_cmd="$3"
  local label="${4:-$cmd}"
  ((CHECKS++)) || true
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} missing $label"
    ((FAILED_CHECKS++)) || true
    return
  fi
  local actual
  actual=$(bash -o pipefail -c "$actual_cmd" 2>/dev/null || true)
  if [[ "$actual" == "$expected" ]]; then
    echo -e "  ${GREEN}✓${NC} $label $actual"
  else
    echo -e "  ${YELLOW}⚠${NC} $label expected $expected, found ${actual:-unknown}"
  fi
}

log_step "Dotfiles Doctor"

log_step "Core Commands"
for cmd in git curl wget jq yq make unzip rg fdfind fd fzf fzf-tmux btop zoxide direnv delta hyperfine duf rustc cargo; do
  check_cmd "$cmd"
done
check_cmd batcat bat
check_optional_cmd eza
check_optional_cmd lazygit
check_optional_cmd lazydocker
check_optional_cmd tldr tealdeer
check_optional_cmd sops
check_optional_cmd dust
check_optional_cmd xh
check_optional_cmd tmux

log_step "Runtime Versions"
check_version node "v$(package_version languages node_lts 24.15.0)" 'node --version' "Node.js"
check_version tsc "$(package_version languages typescript 5.9.3)" "tsc --version | awk '{print \$2}'" "TypeScript"
if command -v uv >/dev/null 2>&1; then
  check_version uv "$(package_version languages python 3.14.5)" "uv python find $(package_version languages python 3.14.5) | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+' | head -1" "Python via uv"
else
  check_cmd uv
fi

log_step "Managed Configs"
check_file "$HOME/.config/starship.toml" starship
check_file "$HOME/.tmux.conf" tmux
check_file "$HOME/.zshrc" zsh
check_file "$HOME/.config/nvim/init.lua" nvim

log_step "Environment"
if is_wsl; then
  echo -e "  ${GREEN}✓${NC} WSL detected"
  check_optional_cmd explorer.exe "Windows Explorer interop"
  check_optional_cmd clip.exe "Windows clipboard interop"
else
  echo -e "  ${GREEN}✓${NC} native Linux detected"
fi

log_step "Credential Helper"
if git credential-manager --version >/dev/null 2>&1 || git-credential-manager --version >/dev/null 2>&1 || git-credential-manager-core --version >/dev/null 2>&1; then
  echo -e "  ${GREEN}✓${NC} Git Credential Manager available"
else
  echo -e "  ${YELLOW}⚠${NC} Git Credential Manager not found"
fi

echo -e "\n${BOLD}── Doctor Summary ──${NC}"
echo -e "  Checks: $CHECKS"
echo -e "  Failed: $FAILED_CHECKS"

if [[ $FAILED_CHECKS -gt 0 ]]; then
  exit 1
fi
