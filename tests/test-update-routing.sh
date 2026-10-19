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
cp "$DOTFILES_DIR/.chezmoiexternal.yaml" "$DOTFILES_SOURCE_DIR/.chezmoiexternal.yaml"
cp -a "$DOTFILES_DIR/.chezmoiscripts" "$DOTFILES_SOURCE_DIR/"
cp "$DOTFILES_DIR/scripts/section-state.py" "$DOTFILES_DIR/scripts/section-registry.py" "$DOTFILES_DIR/scripts/sections.json" "$DOTFILES_SOURCE_DIR/scripts/"
cp "$DOTFILES_DIR/scripts/lib.sh" "$DOTFILES_SOURCE_DIR/scripts/lib.sh"
cp -a "$DOTFILES_DIR/scripts/lib" "$DOTFILES_DIR/scripts/dotfiles" "$DOTFILES_SOURCE_DIR/scripts/"
cp "$DOTFILES_DIR/scripts/environment.sh" "$DOTFILES_SOURCE_DIR/scripts/environment.sh"
cp "$DOTFILES_DIR/scripts/chezmoi-network.sh" "$DOTFILES_SOURCE_DIR/scripts/chezmoi-network.sh"
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
# A user virtual environment/custom python3 must not own bootstrap dependencies.
mkdir -p "$TMP_ROOT/venv/bin"
printf '#!/bin/sh\necho "wrong Python interpreter" >&2\nexit 99\n' >"$TMP_ROOT/venv/bin/python3"
chmod +x "$TMP_ROOT/venv/bin/python3"
export VIRTUAL_ENV="$TMP_ROOT/venv"
export PATH="$VIRTUAL_ENV/bin:$PATH"
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
/usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/section-state.py" --source "$DOTFILES_SOURCE_DIR" --state "$DOTFILES_STATE_DIR" record languages
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

# External-only updates affect their owning section, not unrelated tools.
fingerprint() {
  /usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/section-state.py" --source "$DOTFILES_SOURCE_DIR" fingerprint "$1"
}
zsh_before="$(fingerprint zsh)"
tmux_before="$(fingerprint tmux)"
terminal_before="$(fingerprint terminal)"
/usr/bin/python3 - "$DOTFILES_SOURCE_DIR/.chezmoiexternal.yaml" <<'PY'
import sys
from pathlib import Path
import yaml
path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text())
data['.oh-my-zsh']['checksum']['sha256'] = 'f' * 64
path.write_text(yaml.safe_dump(data))
PY
[[ "$(fingerprint zsh)" != "$zsh_before" ]]
[[ "$(fingerprint tmux)" == "$tmux_before" ]]
[[ "$(fingerprint terminal)" == "$terminal_before" ]]

mkdir -p "$TMP_ROOT/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$MOCK_CALLS"\n[ "${FAIL_EXTERNAL:-0}" != 1 ]\n' >"$TMP_ROOT/bin/chezmoi"
chmod +x "$TMP_ROOT/bin/chezmoi"
: >"$MOCK_CALLS"
PATH="$TMP_ROOT/bin:$PATH" "$DOTFILES_DIR/scripts/reconcile-externals.sh" terminal
grep -Fq "apply --source=$DOTFILES_SOURCE_DIR --exclude=scripts --recursive -- $HOME/.fzf" "$MOCK_CALLS"
grep -Fq "verify --source=$DOTFILES_SOURCE_DIR --exclude=scripts --recursive -- $HOME/.fzf" "$MOCK_CALLS"
if PATH="$TMP_ROOT/bin:$PATH" FAIL_EXTERNAL=1 "$DOTFILES_DIR/scripts/reconcile-externals.sh" terminal; then
  printf 'External apply failure was ignored\n' >&2
  exit 1
fi
