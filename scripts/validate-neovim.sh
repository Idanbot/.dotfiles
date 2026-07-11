#!/usr/bin/env bash
# Deterministic Neovim runtime and lock validation.

set -euo pipefail

MODE=quick
case "${1:-}" in
  --quick | '') MODE=quick ;;
  --sync) MODE=sync ;;
  --offline) MODE=offline ;;
  -h | --help)
    printf 'Usage: scripts/validate-neovim.sh [--quick|--offline|--sync]\n'
    exit 0
    ;;
  *)
    printf 'Unknown option: %s\n' "$1" >&2
    exit 2
    ;;
esac

command -v nvim >/dev/null 2>&1 || {
  printf 'nvim is not installed\n' >&2
  exit 1
}
LOCK="$HOME/.config/nvim/lazy-lock.json"
[[ -f "$LOCK" ]] || {
  printf 'Missing %s\n' "$LOCK" >&2
  exit 1
}
jq -e 'type == "object" and all(.[]; has("branch") and has("commit") and (.commit | test("^[0-9a-f]{40}$")))' "$LOCK" >/dev/null
nvim --clean --headless '+lua assert(vim.version().major == 0)' +qa

case "$MODE" in
  quick) ;;
  offline)
    [[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/lazy.nvim" ]] || {
      printf 'Lazy.nvim is not cached; run with --sync once\n' >&2
      exit 1
    }
    NVIM_APPNAME=nvim nvim --headless +qa
    ;;
  sync)
    NVIM_APPNAME=nvim nvim --headless '+Lazy! sync' +qa
    NVIM_APPNAME=nvim nvim --headless +qa
    ;;
esac

printf 'Neovim %s validation passed\n' "$MODE"
