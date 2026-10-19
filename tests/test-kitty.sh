#!/usr/bin/env bash
# Verify Kitty remains versioned, checksum-pinned, updateable, and vertically tabbed.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG="$DOTFILES_DIR/dot_config/private_kitty/kitty.conf.tmpl"
INSTALLER="$DOTFILES_DIR/scripts/install-kitty.sh"
DESKTOP="$DOTFILES_DIR/.chezmoiscripts/run_once_11-install-desktop.sh.tmpl"

version="$(awk '/^terminal:$/ { inside=1; next } inside && $1 == "kitty:" { gsub(/"/, "", $2); print $2; exit }' "$DOTFILES_DIR/packages.yaml")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
grep -Fq 'repo: kovidgoyal/kitty' "$DOTFILES_DIR/packages.meta.yaml"
grep -Fq 'integrity: pinned-sha256' "$DOTFILES_DIR/packages.meta.yaml"
grep -Eq 'sha256_amd64: [0-9a-f]{64}$' "$DOTFILES_DIR/packages.meta.yaml"
grep -Eq 'sha256_arm64: [0-9a-f]{64}$' "$DOTFILES_DIR/packages.meta.yaml"
grep -Fq 'download_verified "$URL" "$ARCHIVE" "sha256:$CHECKSUM"' "$INSTALLER"
grep -Fq '"$DOTFILES_SOURCE_DIR/scripts/install-kitty.sh"' "$DESKTOP"
! grep -Fq 'apt_install kitty' "$DESKTOP"

grep -Fq 'tab_bar_edge left' "$CONFIG"
grep -Fq 'update_check_interval 24' "$CONFIG"
grep -Fq 'map ctrl+shift+t new_tab_with_cwd' "$CONFIG"
grep -Fq 'map ctrl+shift+q close_tab' "$CONFIG"
grep -Fq 'map ctrl+shift+space select_tab' "$CONFIG"
release_spec="$(/usr/bin/python3 "$DOTFILES_DIR/scripts/dotfiles/metadata.py" \
  release-spec "$DOTFILES_DIR/packages.meta.yaml" "$DOTFILES_DIR/packages.yaml" terminal.kitty)"
[[ "$release_spec" == 'kovidgoyal/kitty|v{version}|kitty-{version}-{arch}.txz|x86_64|arm64' ]]
grep -Fq 'kitty --version | grep -Fq "kitty $kitty_version "' \
  "$DOTFILES_DIR/tests/e2e/test-install.sh"

printf 'Kitty management test passed\n'
