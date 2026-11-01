#!/usr/bin/env bash
# Verify system configuration does not depend on optional login-shell variables.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/scripts" "$TMP_ROOT/bin"

cat >"$TMP_ROOT/scripts/lib.sh" <<'EOF'
log_step() { :; }
log_skip() { :; }
log_info() { :; }
log_success() { :; }
log_error() { return 1; }
require_sudo() { :; }
is_ci() { return 0; }
is_installed() { return 0; }
version_ge() { return 0; }
runtime_is_current() { return 0; }
package_version() { printf '2.8.0\n'; }
is_native() { return 1; }
print_summary() { :; }
EOF

cat >"$TMP_ROOT/bin/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == passwd && -n "$2" ]]
printf '%s\n' "$2" >"$MOCK_CAPTURE"
printf '%s:x:1000:1000:Test User:/home/%s:/bin/bash\n' "$2" "$2"
EOF
cat >"$TMP_ROOT/bin/zsh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP_ROOT/bin/getent" "$TMP_ROOT/bin/zsh"

expected_user="$(id -un)"
env -u USER \
  PATH="$TMP_ROOT/bin:$PATH" \
  MOCK_CAPTURE="$TMP_ROOT/captured-user" \
  DOTFILES_CI=true \
  DOTFILES_SOURCE_DIR="$TMP_ROOT" \
  bash "$DOTFILES_DIR/.chezmoiscripts/run_once_12-configure-system.sh.tmpl"

[[ "$(cat "$TMP_ROOT/captured-user")" == "$expected_user" ]]
printf 'System configuration identity test passed\n'

# Exercise real VS Code inventory caching with a synthetic native CLI.
export VSCODE_LIST="$TMP_ROOT/extensions" VSCODE_CALLS="$TMP_ROOT/code-calls"
awk '/^EXTENSIONS=\(/ { inside=1; next } inside && /^\)/ { exit } inside { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' \
  "$DOTFILES_DIR/.chezmoiscripts/run_once_14-install-vscode-extensions.sh.tmpl" >"$VSCODE_LIST"
cat >"$TMP_ROOT/bin/code" <<'CODE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --list-extensions ]]
printf 'query\n' >>"$VSCODE_CALLS"
cat "$VSCODE_LIST"
CODE
chmod +x "$TMP_ROOT/bin/code"
run_vscode() {
  HOME="$TMP_ROOT/home" DOTFILES_STATE_DIR="$TMP_ROOT/home/state" \
    DOTFILES_SOURCE_DIR="$DOTFILES_DIR" PATH="$TMP_ROOT/bin:$PATH" \
    bash "$DOTFILES_DIR/.chezmoiscripts/run_once_14-install-vscode-extensions.sh.tmpl" >/dev/null
}
run_vscode
run_vscode
[[ "$(wc -l <"$VSCODE_CALLS")" == 1 ]]
[[ "$(stat -c %a "$TMP_ROOT/home/state/vscode-extensions.list")" == 600 ]]
DOTFILES_REFRESH_VSCODE=1 run_vscode
[[ "$(wc -l <"$VSCODE_CALLS")" == 2 ]]
touch -d '10 minutes ago' "$TMP_ROOT/home/state/vscode-extensions.list"
run_vscode
[[ "$(wc -l <"$VSCODE_CALLS")" == 3 ]]
printf 'VS Code inventory cache test passed\n'
