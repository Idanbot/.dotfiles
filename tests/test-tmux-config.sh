#!/usr/bin/env bash
# Validate tmux safety, terminal, popup, persistence, and plugin ownership contracts.
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMUX_CONFIG="$DOTFILES_DIR/dot_tmux.conf.tmpl"
EXTERNALS="$DOTFILES_DIR/.chezmoiexternal.yaml"
INSTALLER="$DOTFILES_DIR/.chezmoiscripts/run_once_06-install-tmux-ecosystem.sh.tmpl"
UPDATER="$DOTFILES_DIR/scripts/update-externals.sh"
FAILED=0
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

pass() { printf '  [PASS] %s\n' "$*"; }
fail() {
  printf '  [FAIL] %s\n' "$*" >&2
  FAILED=1
}
assert_contains() {
  local file="$1" value="$2" description="$3"
  grep -Fq -- "$value" "$file" && pass "$description" || fail "$description"
}
assert_absent() {
  local file="$1" value="$2" description="$3"
  if grep -Fq -- "$value" "$file"; then fail "$description"; else pass "$description"; fi
}

printf '\n== tmux configuration contracts ==\n'
assert_contains "$TMUX_CONFIG" 'set -g default-terminal "tmux-256color"' \
  'tmux advertises a tmux-derived terminal'
assert_contains "$TMUX_CONFIG" 'set -as terminal-features ",xterm-kitty:RGB"' \
  'Kitty RGB support uses terminal-features'
assert_contains "$TMUX_CONFIG" 'set -s escape-time 20' \
  'escape timing tolerates Alt and remote terminals'
assert_contains "$TMUX_CONFIG" 'set -g set-clipboard external' \
  'pane applications cannot write the host clipboard directly'
assert_contains "$TMUX_CONFIG" 'tmux -L scratchpad -f /dev/null new-session -A -s scratchpad' \
  'scratchpad uses an isolated unconfigured tmux server'
assert_contains "$TMUX_CONFIG" '-d "#{pane_current_path}"' \
  'scratchpad inherits the active pane directory'
assert_absent "$TMUX_CONFIG" '-E "tmux new-session -A -s scratchpad"' \
  'scratchpad cannot attach to the outer tmux server'
assert_contains "$TMUX_CONFIG" "set -g @resurrect-capture-pane-contents 'off'" \
  'session recovery does not persist pane output'
assert_contains "$TMUX_CONFIG" '#(~/.local/bin/tmux-kube-status)' \
  'status delegates Kubernetes context formatting to cloud-context'
assert_absent "$TMUX_CONFIG" 'kubectl config current-context' \
  'status does not poll kubectl directly'
assert_absent "$TMUX_CONFIG" ' SSH_TTY TERM LANG ' \
  'attaching clients do not overwrite tmux TERM'
for inherited in KRB5CCNAME SSH_AGENT_PID WINDOWID XAUTHORITY; do
  assert_contains "$TMUX_CONFIG" "$inherited" "update-environment preserves $inherited"
done
assert_contains "$TMUX_CONFIG" '${WSL_INTEROP:-unset}' \
  'WSL diagnostics report the real interop variable'
assert_absent "$TMUX_CONFIG" 'WSLGd' 'WSL diagnostics contain no stale variable typo'
assert_contains "$TMUX_CONFIG" 'tmux-cheat-sheet' \
  'cheat-sheet URL handling is delegated to a testable helper'
assert_contains "$DOTFILES_DIR/docs/keybindings.md" '| prefix+M-n |' \
  'generated docs identify the scratchpad as prefix-scoped'

printf '\n== tmux helper behavior ==\n'
mkdir -p "$TEST_TMP/bin"
cat >"$TEST_TMP/bin/cloud-context" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "prompt kubectl" ]] || exit 1
printf 'short-context'
EOF
chmod +x "$TEST_TMP/bin/cloud-context"
kube_status="$(PATH="$TEST_TMP/bin:$PATH" "$DOTFILES_DIR/dot_local/bin/executable_tmux-kube-status")"
if [[ "$kube_status" == $'\U000f10fe short-context' ]]; then
  pass 'Kubernetes status emits its icon and shortened cloud-context value'
else
  fail 'Kubernetes status emits its icon and shortened cloud-context value'
fi

cat >"$TEST_TMP/bin/jq" <<'EOF'
#!/usr/bin/env bash
printf '%s' 'topic%20with%20%3F'
EOF
cat >"$TEST_TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$TMUX_TEST_CURL_ARGS"
printf 'cheat-result'
EOF
cat >"$TEST_TMP/bin/less" <<'EOF'
#!/usr/bin/env bash
cat
EOF
chmod +x "$TEST_TMP/bin/jq" "$TEST_TMP/bin/curl" "$TEST_TMP/bin/less"
cheat_result="$(
  printf 'topic with ?\n' |
    PATH="$TEST_TMP/bin:$PATH" TMUX_TEST_CURL_ARGS="$TEST_TMP/curl-args" \
      "$DOTFILES_DIR/dot_local/bin/executable_tmux-cheat-sheet"
)"
if [[ "$cheat_result" == 'cheat-result' ]] &&
  grep -Fq 'https://cht.sh/topic%20with%20%3F' "$TEST_TMP/curl-args"; then
  pass 'cheat-sheet queries are URL encoded before download'
else
  fail 'cheat-sheet queries are URL encoded before download'
fi

printf '\n== pinned tmux plugins ==\n'
for plugin in tpm tmux-prefix-highlight tmux-resurrect tmux-continuum tmux-battery; do
  target=".tmux/plugins/$plugin"
  assert_contains "$EXTERNALS" "\"$target\":" "$plugin has a chezmoi external"
  if yq -e ".\"$target\".checksum.sha256 | test(\"^[0-9a-f]{64}$\")" "$EXTERNALS" >/dev/null; then
    pass "$plugin has a SHA256 pin"
  else
    fail "$plugin has a SHA256 pin"
  fi
  assert_contains "$INSTALLER" "\$HOME/.tmux/plugins/\$plugin" \
    "$plugin installation is validated without mutable cloning"
  assert_contains "$UPDATER" "update_entry $target " "$plugin participates in external updates"
done
assert_absent "$INSTALLER" 'install_plugins' 'bootstrap never asks TPM to clone mutable branches'

if command -v tmux >/dev/null 2>&1; then
  awk '
    /{{ if not \.is_wsl }}/ { include = 1; next }
    /{{-? else }}/ { include = 0; next }
    /{{-? end }}/ { include = 1; next }
    include && !/^run -b .*tpm/ { print }
    BEGIN { include = 1 }
  ' "$TMUX_CONFIG" >"$TEST_TMP/tmux.conf"
  if HOME="$TEST_TMP" tmux -L dotfiles-tmux-contract -f "$TEST_TMP/tmux.conf" \
    start-server \; source-file "$TEST_TMP/tmux.conf" \; kill-server; then
    pass 'tmux accepts the rendered native configuration'
  else
    fail 'tmux accepts the rendered native configuration'
  fi
else
  printf '  [SKIP] tmux runtime validation (tmux unavailable)\n'
fi

[[ "$FAILED" -eq 0 ]] || exit 1
printf '\ntmux configuration test passed\n'
