#!/usr/bin/env bash
# Install a pinned chezmoi release after verifying its upstream checksum list.

set -euo pipefail

DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"

VERSION="${DOTFILES_CHEZMOI_VERSION:-$(package_version bootstrap chezmoi 2.71.0)}"
if command -v chezmoi >/dev/null 2>&1 && version_ge "$(chezmoi --version)" "$VERSION"; then
  log_skip "chezmoi $VERSION already installed or newer"
  exit 0
fi

case "$(get_arch)" in
  amd64) ARCH=amd64 ;;
  arm64) ARCH=arm64 ;;
  *)
    log_error "Unsupported chezmoi architecture: $(get_arch)"
    exit 1
    ;;
esac

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
asset="chezmoi_${VERSION}_linux_${ARCH}.tar.gz"
base="https://github.com/twpayne/chezmoi/releases/download/v${VERSION}"
log_info "Installing chezmoi $VERSION"
download_verified "$base/$asset" "$tmpdir/$asset" \
  "$base/chezmoi_${VERSION}_checksums.txt" "$asset"
tar -xzf "$tmpdir/$asset" -C "$tmpdir" chezmoi
install_managed_binary "$tmpdir/chezmoi" chezmoi "$VERSION" github:twpayne/chezmoi
log_success "chezmoi $VERSION installed"
