#!/usr/bin/env bash
# test-templates.sh — Validates all chezmoi template files
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

PASSED=0
FAILED=0

echo -e "\n${BOLD}══ Template Validation Test ══${NC}\n"

DOTFILES_DIR="${1:-$HOME/.dotfiles}"

# Check all .tmpl files for balanced delimiters
while IFS= read -r -d '' tmpl; do
  set +o pipefail
  opens=$(grep -o '{{' "$tmpl" 2>/dev/null | wc -l)
  closes=$(grep -o '}}' "$tmpl" 2>/dev/null | wc -l)
  set -o pipefail
  if [[ "$opens" -ne "$closes" ]]; then
    echo -e "  ${RED}✗${NC} $tmpl: unbalanced delimiters ({{ = $opens, }} = $closes)"
    ((FAILED++)) || true
  else
    echo -e "  ${GREEN}✓${NC} $tmpl ($opens template expressions)"
    ((PASSED++)) || true
  fi
done < <(find "$DOTFILES_DIR" -name '*.tmpl' -print0)

echo -e "\n${BOLD}── Results ──${NC}"
echo -e "  ${GREEN}Passed:${NC} $PASSED"
echo -e "  ${RED}Failed:${NC} $FAILED"

if [[ $FAILED -gt 0 ]]; then
  echo -e "\n${RED}${BOLD}TEMPLATE TESTS FAILED${NC}"
  exit 1
else
  echo -e "\n${GREEN}${BOLD}ALL TEMPLATES VALID${NC}"
fi
