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
cp "$DOTFILES_DIR/packages.meta.yaml" "$DOTFILES_SOURCE_DIR/packages.meta.yaml"
cp -a "$DOTFILES_DIR/.chezmoiscripts" "$DOTFILES_SOURCE_DIR/"
cp "$DOTFILES_DIR/scripts/section-state.py" "$DOTFILES_DIR/scripts/sections.json" "$DOTFILES_SOURCE_DIR/scripts/"
cp "$DOTFILES_DIR/scripts/lib.sh" "$DOTFILES_SOURCE_DIR/scripts/lib.sh"
cp "$DOTFILES_DIR/scripts/environment.sh" "$DOTFILES_SOURCE_DIR/scripts/environment.sh"
cp "$DOTFILES_DIR/scripts/reconcile-packages.sh" "$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh"

mock="$TMP_ROOT/mock-run-section"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "$MOCK_CALLS"\n' >"$mock"
chmod +x "$mock"
export MOCK_CALLS="$TMP_ROOT/calls"
export DOTFILES_RUN_SECTION="$mock"
mkdir -p "$DOTFILES_STATE_DIR"
printf 'languages,cloud,system,desktop\n' >"$DOTFILES_STATE_DIR/selected-sections"

"$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh" >/dev/null
first="$(wc -l <"$MOCK_CALLS")"
[[ "$first" -eq 4 ]]
grep -Fxq cloud "$MOCK_CALLS"
grep -Fxq desktop "$MOCK_CALLS"
: >"$MOCK_CALLS"
"$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh" >/dev/null
[[ ! -s "$MOCK_CALLS" ]]
sed -i 's/typescript: "7.0.2"/typescript: "7.0.3"/' "$DOTFILES_SOURCE_DIR/packages.yaml"
"$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh" >/dev/null
[[ "$(<"$MOCK_CALLS")" == languages ]]

for mapping in database:cloud system:system; do
  group="${mapping%:*}"
  expected="${mapping#*:}"
  : >"$MOCK_CALLS"
  sed -i "/^$group:/a\\  review_probe: changed" "$DOTFILES_SOURCE_DIR/packages.yaml"
  "$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh" >/dev/null
  [[ "$(<"$MOCK_CALLS")" == "$expected" ]]
done
: >"$MOCK_CALLS"
sed -i '/^database:/a\  checksum_probe: changed' "$DOTFILES_SOURCE_DIR/packages.meta.yaml"
"$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh" >/dev/null
[[ "$(<"$MOCK_CALLS")" == cloud ]]
: >"$MOCK_CALLS"
sed -i '/^ai_tools:/a\  unselected_probe: changed' "$DOTFILES_SOURCE_DIR/packages.yaml"
"$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh" >/dev/null
[[ ! -s "$MOCK_CALLS" ]]

# Bootstrap's exact successful record operation establishes a reconcile baseline.
sed -i '/^languages:/a\  bootstrap_probe: changed' "$DOTFILES_SOURCE_DIR/packages.yaml"
python3 "$DOTFILES_SOURCE_DIR/scripts/section-state.py" --source "$DOTFILES_SOURCE_DIR" --state "$DOTFILES_STATE_DIR" record languages
"$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh" >/dev/null
[[ ! -s "$MOCK_CALLS" ]]
before_failure="$(<"$DOTFILES_STATE_DIR/package-sections/languages.sha256")"
sed -i '/^languages:/a\  failure_probe: changed' "$DOTFILES_SOURCE_DIR/packages.yaml"
printf '#!/usr/bin/env bash\nexit 37\n' >"$mock"
if "$DOTFILES_SOURCE_DIR/scripts/reconcile-packages.sh" >/dev/null; then
  printf 'reconcile ignored a section failure\n' >&2
  exit 1
fi
[[ "$(<"$DOTFILES_STATE_DIR/package-sections/languages.sha256")" == "$before_failure" ]]

printf 'Update routing test passed\n'
