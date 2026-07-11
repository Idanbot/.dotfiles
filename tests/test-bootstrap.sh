#!/usr/bin/env bash
# Fast bootstrap contract checks. Live installs are tests/e2e/test-install.sh.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

"$DOTFILES_DIR/tests/test-install-options.sh" "$DOTFILES_DIR"
"$DOTFILES_DIR/tests/test-profiles.sh" "$DOTFILES_DIR"
"$DOTFILES_DIR/tests/test-environment.sh" "$DOTFILES_DIR"
"$DOTFILES_DIR/tests/test-version-helpers.sh" "$DOTFILES_DIR"
"$DOTFILES_DIR/tests/test-bootstrap-safety.sh" "$DOTFILES_DIR"

printf 'Fast bootstrap contract passed; live installation is covered by Docker E2E\n'
