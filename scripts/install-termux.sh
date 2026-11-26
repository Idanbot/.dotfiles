#!/usr/bin/env bash
# Render the shared SSH config without applying Ubuntu packages or hooks.
set -euo pipefail

case "${1:-}" in
  -h | --help)
    printf '%s\n' 'Usage: install.sh --profile termux [--print]'
    exit 0
    ;;
  '' | --print) ;;
  *)
    printf '%s\n' 'Usage: install.sh --profile termux [--print]' >&2
    exit 2
    ;;
esac
(($# <= 1)) || exit 2

if [[ -z "${TERMUX_VERSION:-}" || "${PREFIX:-}" != */files/usr || ! -d "$PREFIX" ]]; then
  printf '%s\n' 'Run the Termux profile from native Termux, not from an Ubuntu guest.' >&2
  exit 2
fi
if ! command -v chezmoi >/dev/null 2>&1; then
  printf '%s\n' 'Install the Termux dependencies first: pkg install chezmoi openssh cloudflared' >&2
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render() {
  DOTFILES_TERMUX_SSH=1 chezmoi --source "$root" --config /dev/null --config-format yaml \
    execute-template \
    <"$root/private_dot_ssh/private_config.tmpl"
}
if [[ "${1:-}" == --print ]]; then
  render
  exit
fi

umask 077
directory="$HOME/.ssh"
destination="$directory/config"
if [[ -L "$directory" || -L "$destination" ]]; then
  printf '%s\n' 'Preserving redirected SSH configuration. Use --print to review the template.' >&2
  exit 1
fi
mkdir -p -- "$directory"
candidate="$(mktemp "$directory/.dotfiles-ssh.XXXXXX")"
trap 'rm -f -- "$candidate"' EXIT
render >"$candidate"
if [[ -f "$destination" && ! -L "$destination" ]] && cmp -s -- "$candidate" "$destination"; then
  printf '%s\n' 'Termux SSH config is already current.'
elif ln -T -- "$candidate" "$destination" 2>/dev/null; then
  printf '%s\n' 'Installed Termux SSH config. Keys and Cloudflare authentication remain manual.'
else
  printf '%s\n' 'Preserving existing SSH config. Use --print and merge the settings you want.' >&2
  exit 1
fi
