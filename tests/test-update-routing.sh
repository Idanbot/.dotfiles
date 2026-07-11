#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export DOTFILES_STATE_DIR="$HOME/state"
export DOTFILES_SOURCE_DIR="$TMP_ROOT/source"
mkdir -p "$HOME" "$DOTFILES_SOURCE_DIR/scripts"
cp "$DOTFILES_DIR/packages.yaml" "$DOTFILES_SOURCE_DIR/packages.yaml"
cp "$DOTFILES_DIR/scripts/lib.sh" "$DOTFILES_SOURCE_DIR/scripts/lib.sh"
cp "$DOTFILES_DIR/scripts/environment.sh" "$DOTFILES_SOURCE_DIR/scripts/environment.sh"
cp "$DOTFILES_DIR/scripts/reconcile-packages.sh" "$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh"

mock="$TMP_ROOT/mock-run-section"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "$MOCK_CALLS"\n' >"$mock"
chmod +x "$mock"
export MOCK_CALLS="$TMP_ROOT/calls"
export DOTFILES_RUN_SECTION="$mock"

"$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh" >/dev/null
first="$(wc -l <"$MOCK_CALLS")"
[[ "$first" -eq 10 ]]
grep -Fxq tmux "$MOCK_CALLS"
grep -Fxq desktop "$MOCK_CALLS"
: >"$MOCK_CALLS"
"$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh" >/dev/null
[[ ! -s "$MOCK_CALLS" ]]
sed -i 's/typescript: "7.0.2"/typescript: "7.0.3"/' "$DOTFILES_SOURCE_DIR/packages.yaml"
"$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh" >/dev/null
[[ "$(<"$MOCK_CALLS")" == languages ]]

printf 'Update routing test passed\n'
