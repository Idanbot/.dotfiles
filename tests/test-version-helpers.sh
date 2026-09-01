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
[[ "$(package_version languages node)" == 26.* ]]
[[ "$(package_version languages npm)" == 12.* ]]
[[ "$(package_version languages rust)" == 1.97.1 ]]
[[ "$(package_version languages java)" == 25.* ]]

PARSER_STDERR="$(mktemp)"
package_version cloud cloudflared >/dev/null 2>"$PARSER_STDERR"
package_metadata cloud cloudflared sha256_amd64 >/dev/null 2>>"$PARSER_STDERR"
if [[ -s "$PARSER_STDERR" ]]; then
  cat "$PARSER_STDERR" >&2
  exit 1
fi

RETRY_COUNT=0
retry_fixture() {
  ((RETRY_COUNT++)) || true
  ((RETRY_COUNT >= 3))
}
retry_command "retry fixture" 3 0 retry_fixture
[[ "$RETRY_COUNT" -eq 3 ]]

GO_INDEX_FIXTURE="$(mktemp)"
APT_SOURCE_FIXTURE="$(mktemp -d)"
trap 'rm -f "$GO_INDEX_FIXTURE" "$PARSER_STDERR"; rm -rf "$APT_SOURCE_FIXTURE"' EXIT
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

mkdir -p "$APT_SOURCE_FIXTURE/sources.list.d"
touch \
  "$APT_SOURCE_FIXTURE/sources.list.d/azure-cli.list" \
  "$APT_SOURCE_FIXTURE/sources.list.d/azure-cli.sources"
sudo() { "$@"; }
reconcile_apt_source \
  "$APT_SOURCE_FIXTURE/sources.list.d/azure-cli.sources" \
  $'Types: deb\nURIs: https://packages.example.invalid/azure-cli/\nSuites: noble\nComponents: main' \
  "$APT_SOURCE_FIXTURE/sources.list.d/azure-cli.list"
unset -f sudo
[[ ! -e "$APT_SOURCE_FIXTURE/sources.list.d/azure-cli.list" ]]
grep -Fq 'Types: deb' "$APT_SOURCE_FIXTURE/sources.list.d/azure-cli.sources"
[[ "$(find "$APT_SOURCE_FIXTURE/sources.list.d" -type f | wc -l)" == 1 ]]

printf 'Version helper test passed\n'
