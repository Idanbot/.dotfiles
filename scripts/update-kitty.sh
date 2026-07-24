#!/usr/bin/env bash
# Check, accept, and install a checksum-pinned Kitty update.

set -euo pipefail

DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"

MODE="${1:---check}"
case "$MODE" in
  --check | --apply) ;;
  -h | --help)
    cat <<'USAGE'
Usage:
  update-kitty --check   Compare installed, approved, and upstream versions
  update-kitty --apply   Pin upstream checksums, install, and leave a reviewable diff
USAGE
    exit 0
    ;;
  *)
    printf 'Unknown option: %s\n' "$MODE" >&2
    exit 2
    ;;
esac

approved="$(package_version terminal kitty)"
installed="$("$HOME/.local/kitty.app/bin/kitty" --version 2>/dev/null || printf 'not installed')"
latest="$(github_latest_release kovidgoyal/kitty)"
latest="${latest#v}"

printf 'Installed: %s\nApproved:  %s\nUpstream:  %s\n' "$installed" "$approved" "$latest"
[[ "$MODE" == --apply ]] || exit 0

if version_ge "$approved" "$latest"; then
  log_skip "Kitty $approved is already the latest approved release"
else
  "$DOTFILES_SOURCE_DIR/scripts/update-packages.sh" \
    --apply "terminal.kitty@$latest" \
    --report "$DOTFILES_SOURCE_DIR/.version-update-report"
fi

"$DOTFILES_SOURCE_DIR/scripts/install-kitty.sh"
log_info "Review and commit the manifest, lockfile, and inventory changes"
