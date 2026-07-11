#!/usr/bin/env bash
# Run only install sections whose package manifest slice changed.

set -euo pipefail

DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"

DRY_RUN=false
FORCE=false
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
    -h | --help)
      printf 'Usage: scripts/reconcile-packages.sh [--dry-run] [--force]\n'
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

declare -A MANIFEST_TO_INSTALL=(
  [core]=terminal
  [languages]=languages
  [editor]=neovim
  [cloud]=cloud
  [terminal]="tmux desktop"
  [history]=history
  [fonts]=fonts
  [ai_tools]=ai
  [media]=media
)

changed=0
for manifest_section in core languages editor cloud terminal history fonts ai_tools media; do
  install_sections="${MANIFEST_TO_INSTALL[$manifest_section]}"
  current="$(section_manifest_hash "$manifest_section")"
  previous=""
  [[ -f "$HASH_DIR/$manifest_section.sha256" ]] && previous="$(<"$HASH_DIR/$manifest_section.sha256")"
  if [[ "$FORCE" == true || "$current" != "$previous" ]]; then
    ((changed++)) || true
    log_info "$manifest_section changed -> install section(s) $install_sections"
    if [[ "$DRY_RUN" == false ]]; then
      for install_section in $install_sections; do
        "$RUN_SECTION" "$install_section"
      done
      printf '%s\n' "$current" >"$HASH_DIR/$manifest_section.sha256"
      chmod 600 "$HASH_DIR/$manifest_section.sha256"
    fi
  else
    log_skip "$manifest_section unchanged"
  fi
done

if [[ "$changed" -eq 0 ]]; then
  log_success "Package state is already reconciled"
elif [[ "$DRY_RUN" == true ]]; then
  log_success "$changed package section(s) would be reconciled"
else
  log_success "$changed package section(s) reconciled"
fi
