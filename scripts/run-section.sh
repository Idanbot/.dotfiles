#!/usr/bin/env bash
# run-section.sh — Render and run one install section from the local chezmoi source
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SECTION="${1:-}"

usage() {
  cat <<'USAGE'
Usage: scripts/run-section.sh <section>

Sections:
USAGE
  /usr/bin/python3 "$DOTFILES_DIR/scripts/section-state.py" --source "$DOTFILES_DIR" describe
}

if [[ -z "$SECTION" || "$SECTION" == "-h" || "$SECTION" == "--help" ]]; then
  usage
  exit 0
fi

/usr/bin/python3 "$DOTFILES_DIR/scripts/section-state.py" --source "$DOTFILES_DIR" script "$SECTION" >/dev/null
exec "$DOTFILES_DIR/scripts/install.sh" --source "$DOTFILES_DIR" --only "$SECTION"
