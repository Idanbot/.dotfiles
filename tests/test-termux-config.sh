#!/usr/bin/env bash
# Native Termux contract with real Chezmoi/OpenSSH, but no Android or network.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

export HOME="$temporary/home" PREFIX="$temporary/termux/files/usr" TERMUX_VERSION=fixture
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME" "$PREFIX/bin"
for command in sudo apt-get pkg cloudflared; do
  printf '#!/bin/sh\ntouch "%s"\nexit 99\n' "$temporary/mutation" >"$PREFIX/bin/$command"
  chmod +x "$PREFIX/bin/$command"
done
export PATH="$PREFIX/bin:$PATH"
install_termux() { bash "$root/scripts/install.sh" --profile termux "$@"; }

if (
  unset TERMUX_VERSION
  install_termux
) >"$temporary/non-termux.log" 2>&1; then
  printf 'Unexpected Termux install without Termux environment\n' >&2
  exit 1
fi
install_termux --print >"$temporary/preview"
[[ ! -e "$HOME/.ssh" ]]
[[ ! -e "$HOME/.config" ]]
install_termux
cmp "$temporary/preview" "$HOME/.ssh/config"
[[ "$(stat -c %a "$HOME/.ssh")" == 700 ]]
[[ "$(stat -c %a "$HOME/.ssh/config")" == 600 ]]
for host in rpi4 t420; do
  resolved="$(ssh -G -T -F "$HOME/.ssh/config" "$host")"
  grep -Fxq 'proxyusefdpass no' <<<"$resolved"
  grep -Fxq 'proxycommand cloudflared access ssh --hostname "%h"' <<<"$resolved"
done
grep -Fxq 'Include ~/.ssh/config.local' "$HOME/.ssh/config"
printf 'Host fixture\n    HostName example.invalid\n' >"$HOME/.ssh/config.local"
printf 'synthetic key, never read\n' >"$HOME/.ssh/id_ed25519"
before="$(stat -c '%i:%y' "$HOME/.ssh/config")"
install_termux
[[ "$(stat -c '%i:%y' "$HOME/.ssh/config")" == "$before" ]]
printf '\n# Local edit\n' >>"$HOME/.ssh/config"
before="$(sha256sum "$HOME/.ssh/"*)"
if install_termux; then exit 1; fi
[[ "$(sha256sum "$HOME/.ssh/"*)" == "$before" ]]
mv "$HOME/.ssh" "$HOME/other"
ln -s "$HOME/other" "$HOME/.ssh"
if install_termux; then exit 1; fi
[[ "$(sha256sum "$HOME/.ssh/"*)" == "$before" ]]
[[ ! -e "$temporary/mutation" ]]
printf 'Termux SSH config deployment and preservation passed\n'
