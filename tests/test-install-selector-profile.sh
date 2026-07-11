#!/usr/bin/env bash
# test-install-selector-profile.sh - Validate one install selector profile in Docker
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
INSTALL_SCRIPT="$DOTFILES_DIR/scripts/install.sh"

if [[ $# -lt 4 ]]; then
  echo "usage: $0 <expected-mode> <expected-sections> <expected-apply-scripts> -- [install args...]" >&2
  exit 2
fi

EXPECTED_MODE="$1"
EXPECTED_SECTIONS="$2"
EXPECTED_APPLY="$3"
shift 3
if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ -n "${INSTALL_SELECTOR_INPUT:-}" ]]; then
  OUTPUT="$(printf '%b' "$INSTALL_SELECTOR_INPUT" | "$INSTALL_SCRIPT" "$@" --print-plan 2>&1)"
else
  OUTPUT="$("$INSTALL_SCRIPT" "$@" --print-plan 2>&1)"
fi

if grep -Fxq "mode=$EXPECTED_MODE" <<<"$OUTPUT" &&
  grep -Fxq "sections=$EXPECTED_SECTIONS" <<<"$OUTPUT" &&
  grep -Fxq "apply_scripts=$EXPECTED_APPLY" <<<"$OUTPUT" &&
  grep -Fxq "orchestrator=explicit" <<<"$OUTPUT"; then
  echo "install selector profile passed: $EXPECTED_MODE $EXPECTED_SECTIONS"
else
  echo "install selector profile failed" >&2
  echo "$OUTPUT" >&2
  exit 1
fi
