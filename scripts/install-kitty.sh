#!/usr/bin/env bash
# Install the repository-approved Kitty release from its checksum-pinned archive.

set -euo pipefail

DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"

VERSION="$(package_version terminal kitty)"
ARCH="$(get_arch)"
CHECKSUM="$(package_metadata terminal kitty "sha256_$ARCH")"
TARGET="$HOME/.local/kitty.app"
FORCE=false

if [[ "${1:-}" == --force ]]; then
  FORCE=true
elif (($#)); then
  printf 'Usage: %s [--force]\n' "${0##*/}" >&2
  exit 2
fi

current="$("$TARGET/bin/kitty" --version 2>/dev/null || true)"
if [[ "$FORCE" == false && -x "$TARGET/bin/kitty" ]] && version_ge "$current" "$VERSION"; then
  log_skip "Kitty $VERSION already installed or newer"
  exit 0
fi

case "$ARCH" in
  amd64) RELEASE_ARCH=x86_64 ;;
  arm64) RELEASE_ARCH=arm64 ;;
  *)
    log_error "Unsupported Kitty architecture: $ARCH"
    exit 1
    ;;
esac

ASSET="kitty-${VERSION}-${RELEASE_ARCH}.txz"
URL="https://github.com/kovidgoyal/kitty/releases/download/v${VERSION}/${ASSET}"
PARENT="$(dirname "$TARGET")"
mkdir -p "$PARENT"
STAGING="$(mktemp -d "$PARENT/.kitty-install.XXXXXXXX")"
ARCHIVE="$STAGING/$ASSET"
NEW_APP="$STAGING/kitty.app"
BACKUP="$PARENT/.kitty.app.previous"

cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

log_info "Installing Kitty $VERSION from its checksum-pinned release archive"
download_verified "$URL" "$ARCHIVE" "sha256:$CHECKSUM"
mkdir -p "$NEW_APP"
tar -xJf "$ARCHIVE" -C "$NEW_APP"
[[ -x "$NEW_APP/bin/kitty" && -x "$NEW_APP/bin/kitten" ]] || {
  log_error "Kitty archive is missing its expected executables"
  exit 1
}

rm -rf "$BACKUP"
if [[ -e "$TARGET" ]]; then
  mv "$TARGET" "$BACKUP"
fi
if ! mv "$NEW_APP" "$TARGET"; then
  [[ ! -e "$BACKUP" ]] || mv "$BACKUP" "$TARGET"
  exit 1
fi
rm -rf "$BACKUP"

managed_link "$TARGET/bin/kitty" "$HOME/.local/bin/kitty" kitty "$VERSION"
managed_link "$TARGET/bin/kitten" "$HOME/.local/bin/kitten" kitten "$VERSION"

mkdir -p "$HOME/.local/share/applications"
for desktop_file in kitty.desktop kitty-open.desktop; do
  source_file="$TARGET/share/applications/$desktop_file"
  target_file="$HOME/.local/share/applications/$desktop_file"
  [[ -f "$source_file" ]] || continue
  cp "$source_file" "$target_file"
  sed -i \
    -e "s|Icon=kitty|Icon=$TARGET/share/icons/hicolor/256x256/apps/kitty.png|g" \
    -e "s|Exec=kitty|Exec=$TARGET/bin/kitty|g" \
    "$target_file"
done

record_install kitty "$VERSION" github:kovidgoyal/kitty "$TARGET"
log_success "$("$TARGET/bin/kitty" --version) installed"
((_INSTALLED++)) || true
