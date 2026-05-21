#!/usr/bin/env bash
# test-idempotency.sh — Verifies bootstrap can be run twice without errors
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "\n${BOLD}══ Idempotency Test ══${NC}\n"

# Copy dotfiles
cp -r /dotfiles "$HOME/.dotfiles" 2>/dev/null || true
chmod +x "$HOME/.dotfiles/scripts/lib.sh"
find "$HOME/.dotfiles" -name '*.sh' -exec chmod +x {} \;

source "$HOME/.dotfiles/scripts/lib.sh"

# Run core package install twice
echo -e "${BOLD}── First run ──${NC}"
sudo apt-get update -qq
apt_install git curl wget jq
echo -e "\n${BOLD}── Second run (should all skip) ──${NC}"
apt_install git curl wget jq

# Verify skip messages
echo -e "\n${BOLD}── Idempotency Check ──${NC}"
if [[ $_SKIPPED -ge 4 ]]; then
  echo -e "  ${GREEN}✓${NC} All packages correctly skipped on second run ($_SKIPPED skipped)"
else
  echo -e "  ${RED}✗${NC} Expected at least 4 skipped, got $_SKIPPED"
  exit 1
fi

echo -e "\n${GREEN}${BOLD}IDEMPOTENCY TEST PASSED${NC}"
