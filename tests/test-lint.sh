#!/usr/bin/env bash
# test-lint.sh — Run all linters locally
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

ERRORS=0
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

echo -e "\n${BOLD}══ Lint Suite ══${NC}\n"

# ── shellcheck ────────────────────────────────────────────────────────────────
if command -v shellcheck &>/dev/null; then
  echo -e "${BOLD}── shellcheck ──${NC}"
  find "$DOTFILES_DIR" -name '*.sh' | while read -r f; do
    if shellcheck -x -S warning "$f" 2>/dev/null; then
      echo -e "  ${GREEN}✓${NC} $f"
    else
      echo -e "  ${RED}✗${NC} $f"
      ((ERRORS++)) || true
    fi
  done
else
  echo -e "  ${YELLOW}⚠${NC} shellcheck not installed — skipping"
fi

# ── shfmt ─────────────────────────────────────────────────────────────────────
if command -v shfmt &>/dev/null; then
  echo -e "\n${BOLD}── shfmt ──${NC}"
  if shfmt -d -i 2 -ci "$DOTFILES_DIR" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} All files formatted correctly"
  else
    echo -e "  ${RED}✗${NC} Formatting issues found"
    ((ERRORS++)) || true
  fi
else
  echo -e "  ${YELLOW}⚠${NC} shfmt not installed — skipping"
fi

# ── yamllint ──────────────────────────────────────────────────────────────────
if command -v yamllint &>/dev/null; then
  echo -e "\n${BOLD}── yamllint ──${NC}"
  if yamllint -d relaxed "$DOTFILES_DIR" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} All YAML files valid"
  else
    echo -e "  ${YELLOW}⚠${NC} YAML lint warnings"
  fi
else
  echo -e "  ${YELLOW}⚠${NC} yamllint not installed — skipping"
fi

if [[ $ERRORS -gt 0 ]]; then
  echo -e "\n${RED}${BOLD}LINT FAILED ($ERRORS errors)${NC}"
  exit 1
else
  echo -e "\n${GREEN}${BOLD}ALL LINTS PASSED${NC}"
fi
