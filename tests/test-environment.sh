#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=scripts/environment.sh
source "$DOTFILES_DIR/scripts/environment.sh"

DOTFILES_WSL=true is_wsl
DOTFILES_WSL=false is_native
[[ "$(DOTFILES_WSL=true get_platform)" == ubuntu-24.04-wsl ]]
[[ "$(DOTFILES_WSL=false get_platform)" == ubuntu-24.04-native ]]
[[ "$(get_arch)" =~ ^(amd64|arm64|armhf)$ ]]
assert_supported_platform

set +e
DOTFILES_WSL=invalid is_wsl >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]]

printf 'Environment detection test passed\n'
