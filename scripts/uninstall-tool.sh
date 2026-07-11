#!/usr/bin/env bash
# Remove only paths recorded in the managed-install ledger.

set -euo pipefail

INCLUDE_PACKAGES=false
DRY_RUN=false
TOOL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-packages)
      INCLUDE_PACKAGES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h | --help)
      printf 'Usage: scripts/uninstall-tool.sh [--dry-run] [--include-packages] <tool>\n'
      exit 0
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      TOOL="$1"
      shift
      ;;
  esac
done
[[ -n "$TOOL" ]] || {
  printf 'A tool name is required\n' >&2
  exit 2
}

STATE_ROOT="${DOTFILES_STATE_DIR:-$HOME/.local/state/dotfiles}"
LEDGER="$STATE_ROOT/installed.tsv"
[[ -f "$LEDGER" ]] || {
  printf 'No managed-install ledger exists\n' >&2
  exit 1
}

safe_target() {
  local target="$1"
  [[ "$target" == "$HOME/.local/"* || "$target" == "$HOME/.cargo/"* || "$target" == /usr/local/* ]]
}

matches="$(awk -F '\t' -v tool="$TOOL" '$1 == tool' "$LEDGER")"
[[ -n "$matches" ]] || {
  printf '%s is not recorded as managed\n' "$TOOL"
  exit 0
}

while IFS=$'\t' read -r tool _version owner target _section _installed_at; do
  case "$owner" in
    apt)
      if [[ "$INCLUDE_PACKAGES" == true ]]; then
        [[ "$DRY_RUN" == true ]] && printf 'would apt remove %s\n' "$target" || sudo apt-get remove -y "$target"
      else
        printf 'preserved apt package %s (use --include-packages to remove)\n' "$target"
        continue
      fi
      ;;
    npm:*)
      package="${owner#npm:}"
      prefix="$HOME/.local/share/npm"
      [[ "$DRY_RUN" == true ]] && printf 'would npm uninstall %s\n' "$package" || npm uninstall --global --prefix "$prefix" "$package"
      ;;
    uv)
      [[ "$DRY_RUN" == true ]] && printf 'would uv tool uninstall %s\n' "$tool" || uv tool uninstall "$tool"
      ;;
    dpkg)
      if [[ "$INCLUDE_PACKAGES" == true ]]; then
        [[ "$DRY_RUN" == true ]] && printf 'would apt remove %s\n' "$target" || sudo apt-get remove -y "$target"
      else
        printf 'preserved dpkg package %s (use --include-packages to remove)\n' "$target"
        continue
      fi
      ;;
    *)
      safe_target "$target" || {
        printf 'Refusing unsafe ledger path: %s\n' "$target" >&2
        exit 1
      }
      if [[ "$DRY_RUN" == true ]]; then
        printf 'would remove %s\n' "$target"
      else
        rm -rf -- "$target"
        printf 'removed %s\n' "$target"
      fi
      ;;
  esac
done <<<"$matches"

if [[ "$DRY_RUN" == false ]]; then
  awk -F '\t' -v tool="$TOOL" '$1 != tool' "$LEDGER" >"$LEDGER.tmp"
  mv "$LEDGER.tmp" "$LEDGER"
  chmod 600 "$LEDGER"
fi
