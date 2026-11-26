#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=scripts/environment.sh
source "$DOTFILES_DIR/scripts/environment.sh"

DOTFILES_WSL=true is_wsl
DOTFILES_WSL=false is_native
release="$(dotfiles_os_version)"
[[ "$(DOTFILES_WSL=true get_platform)" == "ubuntu-$release-wsl" ]]
[[ "$(DOTFILES_WSL=false get_platform)" == "ubuntu-$release-native" ]]
[[ "$(get_arch)" =~ ^(amd64|arm64|armhf)$ ]]
assert_supported_platform

(
  dotfiles_os_id() { printf 'ubuntu\n'; }
  dotfiles_os_version() { printf '%s\n' "$release"; }
  for release in 24.04 26.04; do
    assert_supported_platform
  done
  release=25.10
  ! DOTFILES_ALLOW_UNSUPPORTED=0 assert_supported_platform
  release=26.04
  dotfiles_os_id() { printf 'debian\n'; }
  ! DOTFILES_ALLOW_UNSUPPORTED=0 assert_supported_platform
)

set +e
DOTFILES_WSL=invalid is_wsl >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]]

printf 'Environment detection test passed\n'
