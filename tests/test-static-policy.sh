#!/usr/bin/env bash
# test-static-policy.sh — Fast repository policy checks for the CI gate
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
FAILED=0

pass() { echo -e "  ${GREEN}✓${NC} $*"; }
fail() {
  echo -e "  ${RED}✗${NC} $*"
  FAILED=1
}

echo -e "\n${BOLD}══ Static Policy Test ══${NC}\n"

check_git_whitespace() {
  if ! git -C "$DOTFILES_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 2
  fi

  if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
    git -C "$DOTFILES_DIR" fetch --depth=1 origin "$GITHUB_BASE_REF"
    git -C "$DOTFILES_DIR" diff --check "origin/$GITHUB_BASE_REF...HEAD"
  elif [[ "${GITHUB_ACTIONS:-}" == "true" ]] && git -C "$DOTFILES_DIR" rev-parse HEAD^ >/dev/null 2>&1; then
    git -C "$DOTFILES_DIR" diff --check HEAD^ HEAD
  else
    git -C "$DOTFILES_DIR" diff --check
  fi
}

if check_git_whitespace; then
  pass "git diff whitespace check passed"
else
  case $? in
    2)
      if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        fail "git repository metadata is required in CI"
      else
        pass "git diff whitespace check skipped outside a git worktree"
      fi
      ;;
    *)
      fail "git diff whitespace check failed"
      ;;
  esac
fi

json_failed=0
while IFS= read -r -d '' json_file; do
  if ! jq empty "$json_file" >/dev/null; then
    echo "    invalid JSON: ${json_file#$DOTFILES_DIR/}"
    json_failed=1
  fi
done < <(
  find "$DOTFILES_DIR" \
    -path "$DOTFILES_DIR/.git" -prune -o \
    -type f \
    -name '*.json' \
    -print0
)
if [[ $json_failed -eq 0 ]]; then
  pass "JSON files parse cleanly"
else
  fail "one or more JSON files are invalid"
fi

missing_exec=$(
  find "$DOTFILES_DIR/scripts" "$DOTFILES_DIR/tests" \
    -type f \
    -name '*.sh' \
    ! -perm -111 \
    -print
)
if [[ -z "$missing_exec" ]]; then
  pass "script and test shell files are executable"
else
  echo "$missing_exec" | sed "s#^$DOTFILES_DIR/#    missing executable bit: #"
  fail "some shell entrypoints are not executable"
fi

if "$DOTFILES_DIR/tests/test-templates.sh" "$DOTFILES_DIR"; then
  pass "rendered shell templates parse cleanly"
else
  fail "rendered shell template validation failed"
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

"$DOTFILES_DIR/scripts/generate-tool-inventory.sh" "$tmpdir/tool-inventory.md"
if cmp -s "$tmpdir/tool-inventory.md" "$DOTFILES_DIR/docs/tool-inventory.md"; then
  pass "tool inventory doc is fresh"
else
  diff -u "$DOTFILES_DIR/docs/tool-inventory.md" "$tmpdir/tool-inventory.md" || true
  fail "tool inventory doc is stale"
fi

"$DOTFILES_DIR/scripts/generate-keybinding-docs.sh" "$tmpdir/keybindings.md"
if cmp -s "$tmpdir/keybindings.md" "$DOTFILES_DIR/docs/keybindings.md"; then
  pass "keybinding doc is fresh"
else
  diff -u "$DOTFILES_DIR/docs/keybindings.md" "$tmpdir/keybindings.md" || true
  fail "keybinding doc is stale"
fi

if python3 - "$DOTFILES_DIR" <<'PYTEST'; then
from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote

root = Path(sys.argv[1]).resolve()
failures: list[str] = []
link_pattern = re.compile(r"(?<!!)\[[^\]\n]+\]\(([^)\n]+)\)")


def ignored_target(target: str) -> bool:
    return (
        not target
        or target.startswith("#")
        or target.startswith("http://")
        or target.startswith("https://")
        or target.startswith("mailto:")
        or target.startswith("tel:")
    )


for markdown in sorted(root.rglob("*.md")):
    if ".git" in markdown.parts:
        continue
    text = markdown.read_text(encoding="utf-8")
    relative = markdown.relative_to(root)

    fence_open = False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fence_open = not fence_open
    if fence_open:
        failures.append(f"{relative}: unclosed fenced code block")

    for match in link_pattern.finditer(text):
        target = match.group(1).strip().split()[0].strip("<>")
        if ignored_target(target):
            continue

        path_part = target.split("#", 1)[0]
        if ignored_target(path_part):
            continue

        candidate = root / path_part.lstrip("/") if path_part.startswith("/") else markdown.parent / unquote(path_part)
        if not candidate.exists():
            failures.append(f"{relative}: missing local link target {target}")

if failures:
    for failure in failures:
        print(failure)
    raise SystemExit(1)
PYTEST
  pass "Markdown local links and fenced code blocks are valid"
else
  fail "Markdown link/style check failed"
fi

if [[ $FAILED -gt 0 ]]; then
  echo -e "\n${RED}${BOLD}STATIC POLICY TEST FAILED${NC}"
  exit 1
fi

echo -e "\n${GREEN}${BOLD}STATIC POLICY TEST PASSED${NC}"
