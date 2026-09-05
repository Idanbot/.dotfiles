#!/usr/bin/env bash
# Run only install sections whose package manifest slice changed.

set -euo pipefail

DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"

DRY_RUN=false
FORCE=false
SECTIONS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --sections)
      SECTIONS="${2:?--sections requires a selection}"
      shift 2
      ;;
    -h | --help)
      printf 'Usage: scripts/reconcile-packages.sh [--dry-run] [--force] [--sections a,b]\n'
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

STATE_ROOT="$(managed_state_root)"
HASH_DIR="$STATE_ROOT/package-sections"
RUN_SECTION="${DOTFILES_RUN_SECTION:-$DOTFILES_SOURCE_DIR/scripts/run-section.sh}"
mkdir -p "$HASH_DIR"
state_command=(python3 "$DOTFILES_SOURCE_DIR/scripts/section-state.py" --source "$DOTFILES_SOURCE_DIR" --state "$STATE_ROOT")
[[ -n "$SECTIONS" ]] || SECTIONS="$("${state_command[@]}" selected)"
IFS=, read -r -a selected <<<"$SECTIONS"
declare -A wanted=()
for section in "${selected[@]}"; do
  "${state_command[@]}" script "$section" >/dev/null
  wanted["$section"]=1
done

changed=0
while IFS= read -r manifest_section; do
  [[ -n "${wanted[$manifest_section]:-}" ]] || continue
  current="$("${state_command[@]}" fingerprint "$manifest_section")"
  previous=""
  [[ -f "$HASH_DIR/$manifest_section.sha256" ]] && previous="$(<"$HASH_DIR/$manifest_section.sha256")"
  if [[ "$FORCE" == true || "$current" != "$previous" ]]; then
    ((changed++)) || true
    log_info "$manifest_section inputs changed"
    if [[ "$DRY_RUN" == false ]]; then
      "$RUN_SECTION" "$manifest_section"
      "${state_command[@]}" record "$manifest_section"
    fi
  else
    log_skip "$manifest_section unchanged"
  fi
done < <("${state_command[@]}" list)

if [[ "$changed" -eq 0 ]]; then
  log_success "Package state is already reconciled"
elif [[ "$DRY_RUN" == true ]]; then
  log_success "$changed package section(s) would be reconciled"
else
  log_success "$changed package section(s) reconciled"
fi
