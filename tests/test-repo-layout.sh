#!/usr/bin/env bash
# test-repo-layout.sh — Validates repository script placement conventions
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
FAILED=0

echo -e "\n${BOLD}══ Repository Layout Test ══${NC}\n"

if [[ -f "$DOTFILES_DIR/scripts/install.sh" ]]; then
  echo -e "  ${GREEN}✓${NC} bootstrap script lives in scripts/"
else
  echo -e "  ${RED}✗${NC} missing scripts/install.sh"
  FAILED=1
fi

if [[ -d "$DOTFILES_DIR/.chezmoiscripts" ]]; then
  echo -e "  ${GREEN}✓${NC} chezmoi scripts live in .chezmoiscripts/"
else
  echo -e "  ${RED}✗${NC} missing .chezmoiscripts/"
  FAILED=1
fi

if grep -R '\$HOME/.dotfiles/scripts/lib.sh' \
  "$DOTFILES_DIR/.chezmoiscripts" >/dev/null; then
  echo -e "  ${RED}✗${NC} chezmoi scripts hard-code ~/.dotfiles"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} chezmoi scripts use the source directory"
fi

while IFS= read -r -d '' script; do
  echo -e "  ${RED}✗${NC} root script found: ${script#$DOTFILES_DIR/}"
  FAILED=1
done < <(
  find "$DOTFILES_DIR" \
    -maxdepth 1 \
    -type f \
    \( -name '*.sh' -o -name '*.sh.tmpl' \) \
    -print0
)

if [[ $FAILED -gt 0 ]]; then
  echo -e "\n${RED}${BOLD}REPOSITORY LAYOUT TEST FAILED${NC}"
  exit 1
fi

echo -e "\n${GREEN}${BOLD}REPOSITORY LAYOUT TEST PASSED${NC}"
