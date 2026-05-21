#!/usr/bin/env bash
# test-templates.sh — Validates all chezmoi template files and rendered config syntax
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

DOTFILES_DIR="${1:-$HOME/.dotfiles}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

pass() {
  echo -e "  ${GREEN}✓${NC} $*"
  ((PASSED++)) || true
}
fail() {
  echo -e "  ${RED}✗${NC} $*"
  ((FAILED++)) || true
}
skip() {
  echo -e "  ${YELLOW}⚠${NC} $*"
  ((SKIPPED++)) || true
}

render_template() {
  local src="$1" dest="$2" is_wsl="$3"
  awk -v is_wsl="$is_wsl" -v source_dir="$DOTFILES_DIR" '
    function emit(line) {
      gsub(/{{ \.chezmoi\.sourceDir }}/, source_dir, line)
      gsub(/{{ \.chezmoi\.sourceFile }}/, source_dir, line)
      gsub(/{{ \.sessionizer_dirs }}/, "~/Code ~/Scripts ~/Education", line)
      gsub(/{{ \.email }}/, "test@example.com", line)
      gsub(/{{ \.name }}/, "Test User", line)
      gsub(/{{ include "packages.yaml" \| sha256sum }}/, "test-packages-hash", line)
      print line
    }
    /^[[:space:]]*{{-? if \.is_wsl }}[[:space:]]*$/ { stack[++depth] = include; include = include && (is_wsl == "true"); next }
    /^[[:space:]]*{{ if not \.is_wsl }}[[:space:]]*$/ { stack[++depth] = include; include = include && (is_wsl != "true"); next }
    /^[[:space:]]*{{-? else }}[[:space:]]*$/ { parent = stack[depth]; include = parent && !include; next }
    /^[[:space:]]*{{-? end }}[[:space:]]*$/ { include = stack[depth--]; next }
    BEGIN { include = 1; depth = 0 }
    { if (include) emit($0) }
  ' "$src" > "$dest"
}

echo -e "\n${BOLD}══ Template Validation Test ══${NC}\n"

while IFS= read -r -d '' tmpl; do
  set +o pipefail
  opens=$(grep -o '{{' "$tmpl" 2>/dev/null | wc -l)
  closes=$(grep -o '}}' "$tmpl" 2>/dev/null | wc -l)
  set -o pipefail
  if [[ "$opens" -ne "$closes" ]]; then
    fail "$tmpl: unbalanced delimiters ({{ = $opens, }} = $closes)"
  else
    pass "$tmpl has balanced delimiters ($opens template expressions)"
  fi
done < <(find "$DOTFILES_DIR" -name '*.tmpl' -print0)

for profile in native wsl; do
  is_wsl=false
  [[ "$profile" == "wsl" ]] && is_wsl=true
  echo -e "\n${BOLD}── Rendered Syntax ($profile) ──${NC}"

  while IFS= read -r -d '' tmpl; do
    rel=${tmpl#"$DOTFILES_DIR"/}
    rendered="$TMP_DIR/${profile}-${rel//\//__}"
    render_template "$tmpl" "$rendered" "$is_wsl"

    case "$rel" in
      .chezmoiscripts/*.tmpl|dot_local/bin/*.tmpl)
        if bash -n "$rendered"; then
          pass "$rel renders as valid shell"
        else
          fail "$rel renders with shell syntax errors"
        fi
        ;;
      dot_tmux.conf.tmpl)
        if command -v tmux >/dev/null 2>&1; then
          if tmux -L "dotfiles-template-${profile}" -f "$rendered" start-server \; source-file "$rendered" \; kill-server; then
            pass "$rel renders as valid tmux config"
          else
            fail "$rel renders with tmux syntax errors"
          fi
        else
          skip "tmux not installed; skipped rendered tmux parse"
        fi
        ;;
      dot_gitconfig.tmpl)
        if git config --file "$rendered" --list >/dev/null; then
          pass "$rel renders as valid gitconfig"
        else
          fail "$rel renders with gitconfig syntax errors"
        fi
        ;;
    esac
  done < <(find "$DOTFILES_DIR" -name '*.tmpl' -print0)
done

echo -e "\n${BOLD}── Results ──${NC}"
echo -e "  ${GREEN}Passed:${NC}  $PASSED"
echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED"
echo -e "  ${RED}Failed:${NC}  $FAILED"

if [[ $FAILED -gt 0 ]]; then
  echo -e "\n${RED}${BOLD}TEMPLATE TESTS FAILED${NC}"
  exit 1
fi

echo -e "\n${GREEN}${BOLD}ALL TEMPLATES VALID${NC}"
