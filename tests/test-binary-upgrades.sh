#!/usr/bin/env bash
# Upgrade legacy binaries only after explicit per-tool consent and durable backup.
set -euo pipefail
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
export HOME="$temporary/home" DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
export DOTFILES_STATE_DIR="$HOME/state"
export PATH="$HOME/.local/bin:$PATH"
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

# Unknown versions are not proof that even a digest-owned runtime is obsolete.
unset DOTFILES_REPLACE_BINARIES
printf '#!/bin/sh\necho unknown\n' >"$HOME/.local/bin/runtime-fixture"
chmod +x "$HOME/.local/bin/runtime-fixture"
record_install runtime-fixture unknown test "$HOME/.local/bin/runtime-fixture"
target_is_owned "$HOME/.local/bin/runtime-fixture"
runtime_is_current runtime-fixture 3.0.0 ''
runtime_is_current runtime-fixture 3.0.0 'version unavailable'
export DOTFILES_REPLACE_BINARIES=runtime-fixture-other
runtime_is_current runtime-fixture 3.0.0 unknown
export DOTFILES_REPLACE_BINARIES=runtime-fixture
if runtime_is_current runtime-fixture 3.0.0 unknown; then
  printf 'Named replacement unexpectedly preserved the unknown runtime\n' >&2
  exit 1
fi
unset DOTFILES_REPLACE_BINARIES
if runtime_is_current absent-runtime-fixture 3.0.0 ''; then
  printf 'Missing runtime unexpectedly treated as installed\n' >&2
  exit 1
fi

# Runtime command shims support the same consent/backup migration as binaries.
printf '#!/bin/sh\necho old\n' >"$HOME/.local/bin/fixture-link"
chmod +x "$HOME/.local/bin/fixture-link"
printf '#!/bin/sh\necho new\n' >"$temporary/new-link-target"
chmod +x "$temporary/new-link-target"
if managed_link "$temporary/new-link-target" "$HOME/.local/bin/fixture-link" fixture-runtime 2; then
  printf 'Unapproved legacy link replacement succeeded\n' >&2
  exit 1
fi
DOTFILES_REPLACE_BINARIES=fixture-runtime managed_link "$temporary/new-link-target" "$HOME/.local/bin/fixture-link" fixture-runtime 2
[[ "$("$HOME/.local/bin/fixture-link")" == new ]]
backup="$(find "$DOTFILES_STATE_DIR/binary-backups" -name fixture-link -type f)"
[[ "$(sh "$backup")" == old ]]
target_is_owned "$HOME/.local/bin/fixture-link"
printf 'Legacy binary preservation and explicit upgrade tests passed\n'
