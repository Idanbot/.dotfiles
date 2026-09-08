#!/usr/bin/env bash
# Offline font and fzf upgrades exercise actual installer code.
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
export HOME="$temporary/home" DOTFILES_SOURCE_DIR="$ROOT"
export DOTFILES_STATE_DIR="$HOME/state"
export ARCHIVE="$temporary/font.zip"
mkdir -p "$HOME/.local/share/fonts/FiraMono" "$HOME/.fzf/bin"
source "$ROOT/scripts/lib.sh"
/usr/bin/python3 - "$ARCHIVE" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as archive:
    archive.writestr('FiraMonoNerdFont-Regular.ttf', 'new font fixture')
PY
sed '/^source .*scripts\/lib.sh/d' "$ROOT/.chezmoiscripts/run_once_10-install-fonts.sh.tmpl" >"$temporary/fonts.sh"
package_version() { [[ "$2" == nerd_font ]] && printf 'FiraMono\n' || printf '99.0.0\n'; }
nerd_font_registered() { return 0; }
download_verified() { cp "$ARCHIVE" "$2"; }
fc-cache() { return 0; }
run_fonts() {
  bash -c 'source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; eval "$1"; source "$2"' _ \
    "$(declare -f package_version nerd_font_registered download_verified fc-cache)" "$temporary/fonts.sh"
}
font="$HOME/.local/share/fonts/FiraMono/FiraMonoNerdFont-Regular.ttf"
printf 'old font\n' >"$font"
run_fonts
grep -Fxq 'old font' "$font"
record_install FiraMono 1 nerd-fonts "${font%/*}"
run_fonts
grep -Fxq 'new font fixture' "$font"
ledger="$(cat "$DOTFILES_STATE_DIR/installed.tsv")"
run_fonts
[[ "$(cat "$DOTFILES_STATE_DIR/installed.tsv")" == "$ledger" ]]
printf 'local modification\n' >"$font"
if run_fonts; then
  printf 'Modified font was accepted as managed\n' >&2
  exit 1
fi
grep -Fxq 'local modification' "$font"

awk '/^# fzf source/ { block=1 } /^apt_install fd-find/ { exit } block' \
  "$ROOT/.chezmoiscripts/run_once_before_03-install-terminal-tools.sh.tmpl" >"$temporary/fzf.sh"
printf '#!/bin/sh\necho 1.0.0\n' >"$HOME/.fzf/bin/fzf"
cat >"$HOME/.fzf/install" <<'SH'
#!/bin/sh
[ "${FAIL_FZF:-0}" != 1 ] || exit 0
printf '#!/bin/sh\necho 99.0.0\n' >"$HOME/.fzf/bin/fzf"
SH
chmod +x "$HOME/.fzf/bin/fzf" "$HOME/.fzf/install"
run_fzf() {
  bash -c 'source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; package_version() { echo 99.0.0; }; source "$1"' _ "$temporary/fzf.sh"
}
if FAIL_FZF=1 run_fzf; then
  printf 'Stale fzf accepted after an ineffective upgrade\n' >&2
  exit 1
fi
run_fzf
[[ "$("$HOME/.fzf/bin/fzf" --version)" == 99.0.0 ]]
run_fzf
printf 'Managed font and fzf upgrade tests passed\n'
