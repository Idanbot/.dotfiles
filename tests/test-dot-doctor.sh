#!/usr/bin/env bash
# Ensure dot doctor can recover the source used by a local/container install.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SYSTEM_PATH="$PATH"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/home/.local/state/dotfiles" "$TMP_ROOT/bin"
printf '%s\n' "$DOTFILES_DIR" >"$TMP_ROOT/home/.local/state/dotfiles/source"
cat >"$TMP_ROOT/bin/chezmoi" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == source-path ]] && printf '/missing/chezmoi/source\n'
EOF
chmod +x "$TMP_ROOT/bin/chezmoi"

HOME="$TMP_ROOT/home" \
  DOTFILES_STATE_DIR="$TMP_ROOT/home/.local/state/dotfiles" \
  PATH="$TMP_ROOT/bin:$SYSTEM_PATH" \
  "$DOTFILES_DIR/dot_local/bin/executable_dot" doctor --help |
  grep -Fq 'Usage: scripts/doctor.sh'

printf 'Dot doctor source recovery test passed\n'
