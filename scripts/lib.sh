#!/usr/bin/env bash
# Shared, secret-safe utility library for all install sections.

set -euo pipefail

DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/environment.sh
source "$DOTFILES_SOURCE_DIR/scripts/environment.sh"

# Modules are loaded together; their public helpers may call across boundaries.
# shellcheck source=scripts/lib/logging.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib/logging.sh"
# shellcheck source=scripts/lib/downloads.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib/downloads.sh"
# shellcheck source=scripts/lib/ownership.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib/ownership.sh"
# shellcheck source=scripts/lib/packages.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib/packages.sh"
# shellcheck source=scripts/lib/runtimes.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib/runtimes.sh"
# shellcheck source=scripts/lib/managers.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib/managers.sh"
# shellcheck source=scripts/lib/state-lock.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib/state-lock.sh"

# Keep preflight's active executable selection; missing managed directories are
# fallbacks. Installers deliberately prepend a newly selected runtime themselves.
append_runtime_paths "$HOME/.local/bin" "$(npm_global_prefix)/bin" \
  "$HOME/.cargo/bin" "$HOME/.fzf/bin" /usr/local/go/bin
