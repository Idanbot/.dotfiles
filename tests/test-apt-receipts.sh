#!/usr/bin/env bash
# An APT virtual package can resolve successfully without a dpkg version.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export HOME="$fixture" DOTFILES_STATE_DIR="$fixture/state" DOTFILES_SECTION=core
export DOTFILES_SOURCE_DIR="$root"
# shellcheck source=scripts/lib.sh
source "$root/scripts/lib.sh"

apt_env() { [[ "$1" == apt-get ]]; }
dpkg-query() {
  case "$2:$3" in
    '-f=${Version}:virtual-dns') return 0 ;;
    '-f=${Version}:unverified-dns')
      printf '1.0\n'
      return 1
      ;;
    '-f=${Version}:bind9-dnsutils') printf '1:9.20.24-1\n' ;;
    *) return 1 ;;
  esac
}

apt_install virtual-dns unverified-dns bind9-dnsutils
ledger="$DOTFILES_STATE_DIR/installed.tsv"
if [[ "$(cut -f1-5 "$ledger")" != $'bind9-dnsutils\t1:9.20.24-1\tapt\tbind9-dnsutils\tcore' ]]; then
  printf 'APT receipts must describe concrete installed packages with a version\n' >&2
  exit 1
fi
printf 'APT receipt test passed\n'
