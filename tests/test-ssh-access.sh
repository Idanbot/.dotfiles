#!/usr/bin/env bash
# Verify key-passphrase caching and Cloudflare Access SSH delegation.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
MOCK_BIN="$TMP_ROOT/bin"
CALLS="$TMP_ROOT/calls"
mkdir -p "$MOCK_BIN" "$TMP_ROOT/home/.ssh"
touch "$CALLS" "$TMP_ROOT/home/.ssh/id_ed25519" "$TMP_ROOT/home/.ssh/id_ed25519.pub"

make_mock() {
  local name="$1"
  shift
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "%%s\\t%%s\\n" %q "$*" >>%q\n' "$name" "$CALLS"
    printf '%s\n' "$@"
  } >"$MOCK_BIN/$name"
  chmod +x "$MOCK_BIN/$name"
}

make_mock ssh '
if [[ "${1:-}" == -G ]]; then
  case "${2:-}" in
    rpi4) printf "hostname rpi4-ssh.idanbot.uk\n" ;;
    t420) printf "hostname t420.idanbot.uk\n" ;;
    *) printf "hostname %s\n" "${2:-}" ;;
  esac
  printf "identityfile ~/.ssh/id_ed25519\n"
elif [[ "${SSH_ALWAYS_FAIL:-0}" == 1 ]]; then
  exit 255
fi'
make_mock cloudflared 'exit 0'
make_mock ssh-copy-id 'exit 0'
make_mock ssh-add 'exit 0'
make_mock ssh-key-load 'exit 0'
make_mock ssh-keygen '
if [[ "${1:-}" == -y ]]; then
  printf "ssh-ed25519 fixture-public-key\n"
  exit 0
fi
key=""
while (($#)); do
  if [[ "$1" == -f ]]; then
    key="$2"
    break
  fi
  shift
done
[[ -n "$key" ]]
mkdir -p "$(dirname "$key")"
printf "fixture-private-key\n" >"$key"
printf "ssh-ed25519 fixture-public-key\n" >"$key.pub"'

export HOME="$TMP_ROOT/home"
export PATH="$MOCK_BIN:/usr/bin:/bin"
export SSH_AUTH_SOCK="$TMP_ROOT/agent.socket"
touch "$SSH_AUTH_SOCK"

CLOUDFLARE_SSH="$DOTFILES_DIR/dot_local/bin/executable_cloudflare-ssh"
SSH_KEY_LOAD="$DOTFILES_DIR/dot_local/bin/executable_ssh-key-load"

"$CLOUDFLARE_SSH" login rpi4
grep -Fq $'cloudflared\taccess login https://rpi4-ssh.idanbot.uk' "$CALLS"

: >"$CALLS"
"$CLOUDFLARE_SSH" proxy rpi4-ssh.idanbot.uk
grep -Fq $'cloudflared\taccess ssh --hostname rpi4-ssh.idanbot.uk' "$CALLS"

: >"$CALLS"
if SSH_ALWAYS_FAIL=1 "$CLOUDFLARE_SSH" connect rpi4 -v; then
  printf 'cloudflare-ssh connect masked an SSH transport failure\n' >&2
  exit 1
else
  [[ "$?" -eq 255 ]]
fi
! grep -Fq $'cloudflared\taccess login' "$CALLS"
[[ "$(grep -Fc $'ssh\trpi4 -v' "$CALLS")" -eq 1 ]]

: >"$CALLS"
"$CLOUDFLARE_SSH" connect rpi4 -v
! grep -Fq $'cloudflared\taccess login' "$CALLS"
[[ "$(grep -Fc $'ssh\trpi4 -v' "$CALLS")" -eq 1 ]]

: >"$CALLS"
"$CLOUDFLARE_SSH" setup rpi4 --yes
grep -Fq $'ssh-key-load\t--key '"$HOME"$'/.ssh/id_ed25519' "$CALLS"
grep -Fq $'cloudflared\taccess login https://rpi4-ssh.idanbot.uk' "$CALLS"
grep -Fq $'ssh-copy-id\t-i '"$HOME"$'/.ssh/id_ed25519.pub rpi4' "$CALLS"
grep -Fq $'ssh\t-o BatchMode=yes -o ConnectTimeout=15 rpi4 true' "$CALLS"
! grep -Fq $'ssh-keygen\t' "$CALLS"

: >"$CALLS"
new_key="$HOME/.ssh/fresh_ed25519"
"$CLOUDFLARE_SSH" setup t420 --key "$new_key" --yes
grep -Fq $'ssh-keygen\t-t ed25519 -a 100 -f '"$new_key" "$CALLS"
grep -Fq $'ssh-key-load\t--key '"$new_key" "$CALLS"
grep -Fq $'cloudflared\taccess login https://t420.idanbot.uk' "$CALLS"
grep -Fq $'ssh-copy-id\t-i '"$new_key"$'.pub t420' "$CALLS"
grep -Fq $'ssh\t-o BatchMode=yes -o ConnectTimeout=15 t420 true' "$CALLS"
[[ "$(stat -c '%a' "$new_key")" == 600 ]]
[[ "$(stat -c '%a' "$new_key.pub")" == 644 ]]

: >"$CALLS"
"$CLOUDFLARE_SSH" install-key rpi4
grep -Fq $'ssh-copy-id\t-i '"$HOME"$'/.ssh/id_ed25519.pub rpi4' "$CALLS"

: >"$CALLS"
"$SSH_KEY_LOAD" --lifetime 2h
grep -Fq $'ssh-add\t-t 2h '"$HOME"$'/.ssh/id_ed25519' "$CALLS"

: >"$CALLS"
"$SSH_KEY_LOAD" --list
grep -Fq $'ssh-add\t-l' "$CALLS"

: >"$CALLS"
"$SSH_KEY_LOAD" --clear
grep -Fq $'ssh-add\t-D' "$CALLS"

SSH_CONFIG="$DOTFILES_DIR/private_dot_ssh/private_config.tmpl"
grep -Fq 'AddKeysToAgent 8h' "$SSH_CONFIG"
grep -Fq 'ControlPath ~/.ssh/cm-%C' "$SSH_CONFIG"
grep -Fq 'ProxyCommand %d/.local/bin/cloudflare-ssh proxy %h' "$SSH_CONFIG"
grep -Fq 'PreferredAuthentications publickey' "$SSH_CONFIG"
grep -Fq 'PasswordAuthentication no' "$SSH_CONFIG"
grep -Fq 'KbdInteractiveAuthentication no' "$SSH_CONFIG"
grep -Fq 'ConnectTimeout 15' "$SSH_CONFIG"
! grep -Eqi 'password(authentication)?[[:space:]]+yes|password[[:space:]]*=' "$SSH_CONFIG"

printf 'SSH access test passed\n'
