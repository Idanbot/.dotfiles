#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
export DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

[[ ":$PATH:" == *":$HOME/.cargo/bin:"* ]]
[[ ":$PATH:" == *":$HOME/.local/share/npm/bin:"* ]]
[[ ":$PATH:" == *":/usr/local/go/bin:"* ]]

version_equals v1.2.3 'tool 1.2.3'
version_ge 2.0.0 1.99.9
version_ge 1.2.3 1.2.3
! version_ge 1.2.2 1.2.3
version_major_matches 'openjdk 21.0.8' 21
[[ "$(version_compare 1.2.3 1.2.4)" == -1 ]]
[[ "$(version_compare 1.2.4 1.2.3)" == 1 ]]
[[ "$(version_compare 1.2.3 1.2.3)" == 0 ]]
[[ "$(package_version languages node_lts)" == 24.18.0 ]]

GO_INDEX_FIXTURE="$(mktemp)"
trap 'rm -f "$GO_INDEX_FIXTURE"' EXIT
cat >"$GO_INDEX_FIXTURE" <<'JSON'
[
  {
    "version": "go1.26.5",
    "files": [
      {
        "filename": "go1.26.5.linux-amd64.tar.gz",
        "sha256": "5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
      }
    ]
  }
]
JSON
[[ "$(go_checksum_from_index "$GO_INDEX_FIXTURE" go1.26.5.linux-amd64.tar.gz)" == 5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053 ]]
! go_checksum_from_index "$GO_INDEX_FIXTURE" go1.26.5.linux-arm64.tar.gz >/dev/null 2>&1

printf 'Version helper test passed\n'
