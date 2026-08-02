#!/usr/bin/env bash
# Verify mutable vendor installers against explicitly approved checksums.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export DOTFILES_SOURCE_DIR="$DOTFILES_DIR"

# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

verify_installer() {
  local section="$1" key="$2" url="$3" filename="$4" expected
  expected="$(package_metadata "$section" "$key" sha256)"
  download_verified "$url" "$TMP_ROOT/$filename" "sha256:$expected" "$filename"
}

verify_installer \
  ai_tools codex_cli https://chatgpt.com/codex/install.sh codex-install.sh
verify_installer \
  ai_tools antigravity_cli https://antigravity.google/cli/install.sh antigravity-install.sh

printf 'Mutable vendor installer checksum smoke passed\n'
