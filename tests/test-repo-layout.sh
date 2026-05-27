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

INSTALL_SCRIPT="$DOTFILES_DIR/scripts/install.sh"
if grep -Fq 'https://github.com/Idanbot/.dotfiles.git' "$INSTALL_SCRIPT" && ! grep -Fq -- '--ssh' "$INSTALL_SCRIPT"; then
  echo -e "  ${GREEN}✓${NC} bootstrap uses HTTPS repo source"
else
  echo -e "  ${RED}✗${NC} bootstrap should use HTTPS repo source without --ssh"
  FAILED=1
fi

if grep -Fq 'APPLY_EXCLUDES+=(encrypted)' "$INSTALL_SCRIPT"; then
  echo -e "  ${GREEN}✓${NC} bootstrap skips encrypted files after generating a new age key"
else
  echo -e "  ${RED}✗${NC} bootstrap missing encrypted-file skip for new age keys"
  FAILED=1
fi

if grep -R '\$HOME/.dotfiles/scripts/lib.sh' \
  "$DOTFILES_DIR/.chezmoiscripts" >/dev/null; then
  echo -e "  ${RED}✗${NC} chezmoi scripts hard-code ~/.dotfiles"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} chezmoi scripts use the source directory"
fi

if grep -R "{{ .chezmoi.sourceDir }}/scripts/lib.sh" \
  "$DOTFILES_DIR/.chezmoiscripts" >/dev/null; then
  echo -e "  ${RED}✗${NC} chezmoi scripts rely on templating to load scripts/lib.sh"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} chezmoi scripts load scripts/lib.sh from CHEZMOI_SOURCE_DIR"
fi

if grep -Fq "git -C \"\$CHEZMOI_SOURCE\" pull --ff-only" "$INSTALL_SCRIPT"; then
  echo -e "  ${GREEN}✓${NC} bootstrap refreshes existing remote source before apply"
else
  echo -e "  ${RED}✗${NC} bootstrap should refresh existing remote source before apply"
  FAILED=1
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

TERMINAL_TOOLS_SCRIPT="$DOTFILES_DIR/.chezmoiscripts/run_once_before_03-install-terminal-tools.sh.tmpl"
LANGUAGES_SCRIPT="$DOTFILES_DIR/.chezmoiscripts/run_once_04-install-languages.sh.tmpl"

for tool in fzf fd-find ripgrep bat eza lazygit btop sops lazydocker tealdeer; do
  if grep -q "$tool" "$TERMINAL_TOOLS_SCRIPT"; then
    echo -e "  ${GREEN}✓${NC} terminal installer covers $tool"
  else
    echo -e "  ${RED}✗${NC} terminal installer missing $tool"
    FAILED=1
  fi
done

for tool in yq zoxide direnv git-delta hyperfine duf; do
  if grep -q "$tool" "$DOTFILES_DIR/.chezmoiscripts/run_once_before_01-install-core-packages.sh.tmpl"; then
    echo -e "  ${GREEN}✓${NC} core installer covers $tool"
  else
    echo -e "  ${RED}✗${NC} core installer missing $tool"
    FAILED=1
  fi
done

for expected in 'NODE_VERSION="$(package_version languages node_lts 24.15.0)"' 'TYPESCRIPT_VERSION="$(package_version languages typescript 5.9.3)"' 'PYTHON_VERSION="$(package_version languages python 3.14.5)"' 'RUST_VERSION="$(package_version languages rust stable)"' 'CARGO_VERSION="$(package_version languages cargo stable)"' 'npm install -g "typescript@${TYPESCRIPT_VERSION}"' 'uv python install "$PYTHON_VERSION"'; do
  if grep -Fq "$expected" "$LANGUAGES_SCRIPT"; then
    echo -e "  ${GREEN}✓${NC} language installer contains $expected"
  else
    echo -e "  ${RED}✗${NC} language installer missing $expected"
    FAILED=1
  fi
done

if grep -Fq 'ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"' "$TERMINAL_TOOLS_SCRIPT"; then
  echo -e "  ${GREEN}✓${NC} terminal installer creates fd shim"
else
  echo -e "  ${RED}✗${NC} terminal installer missing fd shim"
  FAILED=1
fi

if [[ -x "$DOTFILES_DIR/scripts/doctor.sh" ]]; then
  echo -e "  ${GREEN}✓${NC} doctor script is executable"
else
  echo -e "  ${RED}✗${NC} doctor script missing or not executable"
  FAILED=1
fi

if [[ -x "$DOTFILES_DIR/scripts/generate-package-lock.sh" && -f "$DOTFILES_DIR/packages.lock" && -f "$DOTFILES_DIR/packages.meta.yaml" ]]; then
  echo -e "  ${GREEN}✓${NC} package lock generator and metadata are present"
else
  echo -e "  ${RED}✗${NC} package lock generator, metadata, or lockfile missing"
  FAILED=1
fi

if [[ -x "$DOTFILES_DIR/scripts/generate-keybinding-docs.sh" && -f "$DOTFILES_DIR/docs/keybindings.md" ]]; then
  echo -e "  ${GREEN}✓${NC} keybinding docs generator and doc are present"
else
  echo -e "  ${RED}✗${NC} keybinding docs generator or doc missing"
  FAILED=1
fi

if [[ -x "$DOTFILES_DIR/scripts/generate-tool-inventory.sh" && -f "$DOTFILES_DIR/docs/tool-inventory.md" ]]; then
  tmp_inventory=$(mktemp)
  "$DOTFILES_DIR/scripts/generate-tool-inventory.sh" "$tmp_inventory"
  if cmp -s "$tmp_inventory" "$DOTFILES_DIR/docs/tool-inventory.md"; then
    echo -e "  ${GREEN}✓${NC} tool inventory is up to date"
  else
    echo -e "  ${RED}✗${NC} tool inventory is stale"
    FAILED=1
  fi
  rm -f "$tmp_inventory"
else
  echo -e "  ${RED}✗${NC} tool inventory generator or doc missing"
  FAILED=1
fi

if [[ $FAILED -gt 0 ]]; then
  echo -e "\n${RED}${BOLD}REPOSITORY LAYOUT TEST FAILED${NC}"
  exit 1
fi

echo -e "\n${GREEN}${BOLD}REPOSITORY LAYOUT TEST PASSED${NC}"
