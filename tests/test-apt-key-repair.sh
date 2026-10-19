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
[[ "$(tail -1 "$calls")" == 'apt apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any -qq update' ]]
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

# Execute the real prerequisite stage against a fixture checkout. Repair must
# precede the first APT refresh and a failed refresh must block package installs.
(
  fixture="$temporary/bootstrap"
  mkdir -p "$fixture/scripts"
  touch "$fixture/scripts/hashicorp-keyrings.py"
  cat >"$fixture/scripts/lib.sh" <<'LIB'
refresh_hashicorp_apt_keys() { printf 'repair\n' >>"$BOOTSTRAP_CALLS"; }
LIB
  awk '/^stage_prerequisites\(\)/ {block = 1} /^prepare_run_plan\(\)/ {exit} block' \
    "$DOTFILES_DIR/scripts/install.sh" >"$temporary/prerequisites.sh"
  # shellcheck disable=SC2034
  LOCAL_SOURCE="$fixture"
  export BOOTSTRAP_CALLS="$temporary/bootstrap-calls"
  sudo() {
    [[ "$1" != -v ]] || return 0
    printf '%s\n' "$*" >>"$BOOTSTRAP_CALLS"
    [[ "$*" != *' update' || "${BOOTSTRAP_APT_FAILURE:-0}" == 0 ]]
  }
  id() { printf '1000\n'; }
  chezmoi() { :; }
  log_skip() { :; }
  source "$temporary/prerequisites.sh"
  stage_prerequisites
  [[ "$(head -1 "$BOOTSTRAP_CALLS")" == repair ]]
  grep -Fq APT::Update::Error-Mode=any "$BOOTSTRAP_CALLS"
  : >"$BOOTSTRAP_CALLS"
  if BOOTSTRAP_APT_FAILURE=1 stage_prerequisites; then
    printf 'Bootstrap ignored failed APT refresh\n' >&2
    exit 1
  fi
  ! grep -q ' install ' "$BOOTSTRAP_CALLS"
)
printf 'Scoped APT key repair tests passed\n'
