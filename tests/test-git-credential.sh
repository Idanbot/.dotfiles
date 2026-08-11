#!/usr/bin/env bash
# Reproduce and prevent malformed Git credential helpers on native Ubuntu and WSL.
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home/.ssh"

render_gitconfig() {
  local is_wsl="$1" output="$2"
  awk -v is_wsl="$is_wsl" '
    /{{-? if \.is_wsl }}/ { include = (is_wsl == "true"); next }
    /{{-? if not \.is_wsl }}/ { include = (is_wsl != "true"); next }
    /{{-? else }}/ { include = !include; next }
    /{{-? end }}/ { include = 1; next }
    include { print }
    BEGIN { include = 1 }
  ' "$DOTFILES_DIR/dot_gitconfig.tmpl" >"$output"
}

render_gitconfig true "$TMP_ROOT/gitconfig-wsl"
render_gitconfig false "$TMP_ROOT/gitconfig-native"

for config in "$TMP_ROOT/gitconfig-wsl" "$TMP_ROOT/gitconfig-native"; do
  mapfile -t helpers < <(git config --file "$config" --get-all credential.helper)
  [[ "${helpers[*]}" == ' dotfiles' ]]
  ! grep -Fq 'helper = !f()' "$config"
done

cat >"$TMP_ROOT/bin/git-credential-manager" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == get ]]
cat >/dev/null
printf 'username=fixture-user\npassword=fixture-password\n'
EOF
chmod +x "$TMP_ROOT/bin/git-credential-manager"
ln -s "$DOTFILES_DIR/dot_local/bin/executable_git-credential-dotfiles" \
  "$TMP_ROOT/bin/git-credential-dotfiles"

credential_output="$({
  printf 'protocol=https\nhost=github.com\n\n'
} | HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin" \
  git -c credential.helper= -c credential.helper=dotfiles credential fill)"
grep -Fq 'username=fixture-user' <<<"$credential_output"
grep -Fq 'password=fixture-password' <<<"$credential_output"

cat >"$TMP_ROOT/bin/windows-gcm.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >"$WINDOWS_GCM_OPERATION"
cat >/dev/null
EOF
chmod +x "$TMP_ROOT/bin/windows-gcm.exe"
printf 'protocol=https\nhost=github.com\n\n' |
  WINDOWS_GCM_OPERATION="$TMP_ROOT/windows-operation" \
    GCM_WINDOWS_PATH="$TMP_ROOT/bin/windows-gcm.exe" \
    "$DOTFILES_DIR/dot_local/bin/executable_git-credential-dotfiles" get
[[ "$(cat "$TMP_ROOT/windows-operation")" == get ]]

mkdir -p "$TMP_ROOT/empty-bin"
PATH="$TMP_ROOT/empty-bin:/usr/bin:/bin" \
  GCM_WINDOWS_PATH="$TMP_ROOT/missing-gcm.exe" \
  "$DOTFILES_DIR/dot_local/bin/executable_git-credential-dotfiles" get \
  </dev/null >"$TMP_ROOT/no-helper.out" 2>"$TMP_ROOT/no-helper.err"
[[ ! -s "$TMP_ROOT/no-helper.out" && ! -s "$TMP_ROOT/no-helper.err" ]]

SSH_CONFIG="$DOTFILES_DIR/private_dot_ssh/private_config.tmpl"
! grep -Eq '^[[:space:]]*IdentityFile[[:space:]]' "$SSH_CONFIG"
HOME="$TMP_ROOT/home" ssh -G -F "$SSH_CONFIG" github.com >/dev/null 2>&1
HOME="$TMP_ROOT/home" ssh -G -F "$SSH_CONFIG" rpi4 >/dev/null 2>&1
grep -Fq 'HostName rpi4-ssh.idanbot.uk' "$SSH_CONFIG"
grep -Fq 'ProxyCommand %d/.local/bin/cloudflare-ssh proxy %h' "$SSH_CONFIG"

if git -c safe.directory="$DOTFILES_DIR" -C "$DOTFILES_DIR" ls-files | grep -Eqi \
  '(^|/)(id_(rsa|dsa|ecdsa|ed25519)|[^/]*\.(pem|key|p12|pfx|ppk))$|(^|/)(authorized_keys|known_hosts)$'; then
  printf 'Tracked SSH key or trust material detected\n' >&2
  exit 1
fi

printf 'Git credential and clean SSH configuration test passed\n'
