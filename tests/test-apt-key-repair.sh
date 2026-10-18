#!/usr/bin/env bash
# Discover legacy/Deb822 sources and refresh only their scoped, pinned keyrings.
set -euo pipefail
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
export DOTFILES_SOURCE_DIR="$DOTFILES_DIR" HOME="$temporary/home"
export DOTFILES_APT_SOURCES_DIR="$temporary/apt"
mkdir -p "$HOME" "$DOTFILES_APT_SOURCES_DIR/sources.list.d"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"
calls="$temporary/calls"
sudo() { :; }
gpg() {
  [[ -f "$temporary/current-key" ]] || return 1
  printf 'fpr:::::::::D55C0D1AC78A8D8126CB631CFC9CA96ACA026560:\n'
}
install_apt_key() {
  [[ "$1" == https://apt.releases.hashicorp.com/gpg ]]
  [[ "$3" == D55C0D1AC78A8D8126CB631CFC9CA96ACA026560 ]]
  [[ "${MOCK_KEY_FAILURE:-false}" != true ]] || return 17
  printf 'key %s\n' "$2" >>"$calls"
  touch "$temporary/current-key"
}
apt_env() { printf 'apt %s\n' "$*" >>"$calls"; }
apt_update
[[ "$(wc -l <"$calls")" == 1 ]]
! grep -q '^key ' "$calls"

cat >"$DOTFILES_APT_SOURCES_DIR/sources.list.d/hashicorp.list" <<'APT'
# deb [signed-by=/bad/ignored] https://apt.releases.hashicorp.com noble main
deb [arch=amd64 signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com noble main
APT
: >"$calls"
apt_update
[[ "$(head -1 "$calls")" == 'key /usr/share/keyrings/hashicorp-archive-keyring.gpg' ]]
[[ "$(tail -1 "$calls")" == 'apt apt-get -o Acquire::Retries=3 -qq update' ]]
: >"$calls"
apt_update
[[ "$(wc -l <"$calls")" == 1 ]]

rm "$DOTFILES_APT_SOURCES_DIR/sources.list.d/hashicorp.list" "$temporary/current-key"
cat >"$DOTFILES_APT_SOURCES_DIR/sources.list.d/hashicorp.sources" <<'APT'
Types: deb
URIs: https://apt.releases.hashicorp.com
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/hashicorp.gpg

Types: deb
URIs: https://apt.releases.hashicorp.com
Enabled: no
Signed-By: /bad/disabled
APT
: >"$calls"
source_hash="$(sha256sum "$DOTFILES_APT_SOURCES_DIR/sources.list.d/hashicorp.sources")"
apt_update
grep -Fxq 'key /etc/apt/keyrings/hashicorp.gpg' "$calls"
[[ "$source_hash" == "$(sha256sum "$DOTFILES_APT_SOURCES_DIR/sources.list.d/hashicorp.sources")" ]]
rm "$temporary/current-key"
: >"$calls"
if MOCK_KEY_FAILURE=true apt_update; then
  printf 'Failed signing-key verification was ignored\n' >&2
  exit 1
fi
[[ ! -s "$calls" ]]
sed -i 's@/etc/apt/keyrings/hashicorp.gpg@/etc/apt/keyrings/../trusted.gpg@' \
  "$DOTFILES_APT_SOURCES_DIR/sources.list.d/hashicorp.sources"
if apt_update; then
  printf 'Unsafe signing-key path was accepted\n' >&2
  exit 1
fi
[[ ! -s "$calls" ]]
printf 'Scoped APT key repair tests passed\n'
