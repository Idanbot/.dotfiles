#!/usr/bin/env bash
# Upgrade legacy binaries only after explicit per-tool consent and durable backup.
set -euo pipefail
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
export HOME="$temporary/home" DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
export DOTFILES_STATE_DIR="$HOME/state"
mkdir -p "$HOME/.local/bin" "$temporary/payload"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"
printf '#!/bin/sh\necho "gh version 1.0.0"\n' >"$HOME/.local/bin/gh"
printf '#!/bin/sh\necho "gh version 2.0.0"\n' >"$temporary/payload/gh"
chmod +x "$HOME/.local/bin/gh" "$temporary/payload/gh"
tar -czf "$temporary/gh.tar.gz" -C "$temporary/payload" gh
download_verified() {
  printf '%s\n' "$1" >>"$temporary/downloads"
  cp "$temporary/gh.tar.gz" "$2"
}
upgrade_gh() {
  install_github_archive gh cli/cli v2.0.0 gh.tar.gz gh fixture 'gh --version'
}
upgrade_gh
[[ "$(gh --version)" == 'gh version 1.0.0' && ! -f "$temporary/downloads" ]]
[[ ! -f "$DOTFILES_STATE_DIR/installed.tsv" ]]
export DOTFILES_REPLACE_BINARIES=gh-other
upgrade_gh
[[ "$(gh --version)" == 'gh version 1.0.0' ]]
export DOTFILES_REPLACE_BINARIES=gh
upgrade_gh
[[ "$(gh --version)" == 'gh version 2.0.0' ]]
assert_owned_target "$HOME/.local/bin/gh"
backup="$(find "$DOTFILES_STATE_DIR/binary-backups" -name gh -type f -print)"
[[ "$(sh "$backup")" == 'gh version 1.0.0' ]]
[[ "$(stat -c '%a' "${backup%/*}")" == 700 ]]
upgrade_gh
[[ "$(wc -l <"$temporary/downloads")" == 1 ]]

# Modified managed tools and symlink targets retain the same protection.
unset DOTFILES_REPLACE_BINARIES
printf '#!/bin/sh\necho "gh version 1.5.0 local"\n' >"$HOME/.local/bin/gh"
upgrade_gh
[[ "$(gh --version)" == 'gh version 1.5.0 local' ]]
cp "$HOME/.local/bin/gh" "$temporary/original"
rm "$HOME/.local/bin/gh"
ln -s "$temporary/original" "$HOME/.local/bin/gh"
upgrade_gh
[[ -L "$HOME/.local/bin/gh" ]]
export DOTFILES_REPLACE_BINARIES=gh
upgrade_gh
[[ ! -L "$HOME/.local/bin/gh" ]]
[[ "$(sh "$temporary/original")" == 'gh version 1.5.0 local' ]]
[[ "$(find "$DOTFILES_STATE_DIR/binary-backups" -name gh -type l | wc -l)" == 1 ]]

# A failed candidate probe leaves the legacy tool untouched.
printf '#!/bin/sh\nexit 37\n' >"$temporary/broken"
printf '#!/bin/sh\necho "gh version 1.0.0"\n' >"$HOME/.local/bin/gh"
if install_managed_binary "$temporary/broken" gh 3 github:cli/cli 'gh --version'; then
  printf 'Broken upgrade replaced a working tool\n' >&2
  exit 1
fi
[[ "$(gh --version)" == 'gh version 1.0.0' ]]
printf 'Legacy binary preservation and explicit upgrade tests passed\n'
