#!/usr/bin/env bash
# test-install-options.sh - Validate bootstrap install profile and flag planning
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
INSTALL_SCRIPT="$DOTFILES_DIR/scripts/install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

FAILED=0

run_plan() {
  "$INSTALL_SCRIPT" "$@" --print-plan
}

assert_plan() {
  local label="$1" expected_mode="$2" expected_sections="$3" expected_apply="$4"
  shift 4
  local output
  if ! output=$(run_plan "$@" 2>&1); then
    echo -e "  ${RED}✗${NC} $label failed"
    echo "$output"
    FAILED=1
    return
  fi

  if grep -Fxq "mode=$expected_mode" <<<"$output" &&
    grep -Fxq "sections=$expected_sections" <<<"$output" &&
    grep -Fxq "apply_scripts=$expected_apply" <<<"$output"; then
    echo -e "  ${GREEN}✓${NC} $label"
  else
    echo -e "  ${RED}✗${NC} $label produced unexpected plan"
    echo "$output"
    FAILED=1
  fi
}

assert_menu_plan() {
  local label="$1" input="$2" expected_mode="$3" expected_sections="$4" expected_apply="$5"
  local output
  if ! output=$(printf '%b' "$input" | "$INSTALL_SCRIPT" --menu --print-plan 2>&1); then
    echo -e "  ${RED}✗${NC} $label failed"
    echo "$output"
    FAILED=1
    return
  fi

  if grep -Fxq "mode=$expected_mode" <<<"$output" &&
    grep -Fxq "sections=$expected_sections" <<<"$output" &&
    grep -Fxq "apply_scripts=$expected_apply" <<<"$output"; then
    echo -e "  ${GREEN}✓${NC} $label"
  else
    echo -e "  ${RED}✗${NC} $label produced unexpected plan"
    echo "$output"
    FAILED=1
  fi
}

assert_failure() {
  local label="$1"
  shift
  if "$INSTALL_SCRIPT" "$@" --print-plan >/tmp/dotfiles-install-options.err 2>&1; then
    echo -e "  ${RED}✗${NC} $label should have failed"
    FAILED=1
  else
    echo -e "  ${GREEN}✓${NC} $label"
  fi
  rm -f /tmp/dotfiles-install-options.err
}

assert_output_contains() {
  local label="$1" expected="$2"
  shift 2
  local output
  if ! output=$("$INSTALL_SCRIPT" "$@" 2>&1); then
    echo -e "  ${RED}✗${NC} $label failed"
    echo "$output"
    FAILED=1
    return
  fi
  if grep -Fq "$expected" <<<"$output"; then
    echo -e "  ${GREEN}✓${NC} $label"
  else
    echo -e "  ${RED}✗${NC} $label missing expected output: $expected"
    echo "$output"
    FAILED=1
  fi
}

FULL_SECTIONS="detect,core,zsh,terminal,languages,cloud,tmux,neovim,ai,media,fonts,desktop,system,theme,vscode,services"
BASE_SECTIONS="detect,core,zsh,terminal"

echo -e "\n${BOLD}══ Install Option Plans ══${NC}\n"

assert_plan "default full plan" full "$FULL_SECTIONS" true
assert_plan "explicit full plan" full "$FULL_SECTIONS" true --full
assert_plan "base-only plan" base "$BASE_SECTIONS" false --base-only
assert_plan "base plus languages/tmux" base "detect,core,zsh,terminal,languages,tmux" false --with languages,tmux
assert_plan "base plus equals syntax" base "detect,core,zsh,terminal,neovim,ai" false --with=ai,neovim
assert_plan "exact sections" custom "core,languages" false --sections core,languages
assert_plan "exact sections equals syntax sorted" custom "core,languages" false --sections=languages,core
assert_plan "full without heavy sections" full "detect,core,zsh,terminal,languages,tmux,neovim,ai,media,fonts,desktop,system,theme,services" false --full --without cloud,vscode
assert_plan "yes defaults to full" full "$FULL_SECTIONS" true --yes
assert_menu_plan "menu full" '1\n' full "$FULL_SECTIONS" true
assert_menu_plan "menu base" '2\n' base "$BASE_SECTIONS" false
assert_menu_plan "menu base plus selected" '3\nlanguages,tmux\n' custom "detect,core,zsh,terminal,languages,tmux" false
assert_menu_plan "menu exact selected" '4\ncore,languages\n' custom "core,languages" false
assert_output_contains "list options" "All sections: $FULL_SECTIONS" --list-options
assert_output_contains "help" "Usage: scripts/install.sh [options]" --help
assert_failure "missing only section rejected" --only
assert_failure "unknown section rejected" --sections nope
assert_failure "unknown option rejected" --bogus

if [[ $FAILED -gt 0 ]]; then
  echo -e "\n${RED}${BOLD}INSTALL OPTION TESTS FAILED${NC}"
  exit 1
fi

echo -e "\n${GREEN}${BOLD}INSTALL OPTION TESTS PASSED${NC}"
