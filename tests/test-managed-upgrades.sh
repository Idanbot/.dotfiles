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
before_stamp="$(cat "$(ownership_stamp "${font%/*}")")"
before_ledger="$(cat "$DOTFILES_STATE_DIR/installed.tsv")"
output="$(run_fonts)"
grep -Fq 'Preserving existing' <<<"$output"
grep -Fq 'Preserved: 1' <<<"$output"
grep -Fxq 'local modification' "$font"
[[ "$(cat "$DOTFILES_STATE_DIR/installed.tsv")" == "$before_ledger" ]]
[[ "$(cat "$(ownership_stamp "${font%/*}")")" == "$before_stamp" ]]

# Legacy receipts, missing stamps, and modified older trees must not trigger a
# download or block a run when usable font files remain available on WSL.
for version in 1 99.0.0; do
  for ownership in legacy modified; do
    for registered in true false; do
      (
        export registered
        printf 'existing font\n' >"$font"
        record_install FiraMono "$version" nerd-fonts "${font%/*}"
        case "$ownership" in
          legacy) rm "$(ownership_stamp "${font%/*}")" ;;
          modified) printf 'local edit\n' >>"$font" ;;
        esac
        prior="$(managed_target_digest "${font%/*}")"
        before_ledger="$(cat "$DOTFILES_STATE_DIR/installed.tsv")"
        nerd_font_registered() { [[ "$registered" == true ]]; }
        download_verified() {
          printf 'unexpected download\n' >&2
          return 91
        }
        fc-cache() {
          printf 'unexpected cache mutation\n' >&2
          return 92
        }
        result="$(run_fonts)"
        grep -Fq 'Preserving existing' <<<"$result"
        grep -Fq 'Preserved: 1' <<<"$result"
        [[ "$(managed_target_digest "${font%/*}")" == "$prior" ]]
        [[ "$(cat "$DOTFILES_STATE_DIR/installed.tsv")" == "$before_ledger" ]]
        ! target_is_owned "${font%/*}"
      )
    done
  done
done

# Redirected font parents must never be traversed for an upgrade, even when an
# old receipt exists. Empty protected destinations fail before any download.
for layout in redirected unusable fresh; do
  (
    export HOME="$temporary/$layout" DOTFILES_STATE_DIR="$temporary/$layout/state"
    export DOTFILES_PLATFORM=wsl
    mkdir -p "$HOME/.local/share"
    nerd_font_registered() { return 1; }
    case "$layout" in
      redirected)
        mkdir -p "$HOME/external/FiraMono"
        printf 'keep external font\n' >"$HOME/external/FiraMono/FiraMonoNerdFont-Regular.ttf"
        ln -s "$HOME/external" "$HOME/.local/share/fonts"
        ;;
      unusable) mkdir -p "$HOME/.local/share/fonts/FiraMono" ;;
    esac
    if [[ "$layout" != fresh ]]; then
      download_verified() {
        printf 'unexpected download\n' >&2
        return 91
      }
      fc-cache() {
        printf 'unexpected cache mutation\n' >&2
        return 92
      }
    fi
    if [[ "$layout" == unusable ]]; then
      if result="$(run_fonts 2>&1)"; then
        printf 'Unusable protected font destination accepted\n' >&2
        exit 1
      fi
      grep -Fq 'protected destination has no usable' <<<"$result"
    else
      result="$(run_fonts)"
      if [[ "$layout" == redirected ]]; then
        grep -Fq 'Preserved: 1' <<<"$result"
        grep -Fxq 'keep external font' "$HOME/external/FiraMono/FiraMonoNerdFont-Regular.ttf"
        [[ ! -e "$DOTFILES_STATE_DIR/installed.tsv" ]]
      else
        grep -Fxq 'new font fixture' "$HOME/.local/share/fonts/FiraMono/FiraMonoNerdFont-Regular.ttf"
        target_is_owned "$HOME/.local/share/fonts/FiraMono"
      fi
    fi
  )
done

awk '/^# fzf source/ { block=1 } /^apt_install fd-find/ { exit } block' \
  "$ROOT/.chezmoiscripts/run_once_before_03-install-terminal-tools.sh.tmpl" >"$temporary/fzf.sh"
# Exercise the actual call site with real verification/cache helpers. Neither a
# substituted release nor the source installer may execute before verification.
for arch in amd64 arm64; do
  (
    export arch
    export HOME="$temporary/fzf-$arch" DOTFILES_STATE_DIR="$temporary/fzf-$arch/state"
    export XDG_CACHE_HOME="$HOME/cache" DOTFILES_DOWNLOAD_CACHE=1
    mkdir -p "$HOME/.fzf/bin" "$HOME/fixture"
    printf '#!/bin/sh\necho vendor-installer-ran >>"$HOME/executed"\n' >"$HOME/.fzf/install"
    chmod +x "$HOME/.fzf/install"
    printf '#!/bin/sh\necho payload-ran >>"$HOME/executed"\necho 99.0.0\n' >"$HOME/fixture/fzf"
    chmod +x "$HOME/fixture/fzf"
    tar -czf "$HOME/release.tar.gz" -C "$HOME/fixture" fzf
    printf '%s  fzf-99.0.0-linux_%s.tar.gz\n' "$(sha256_file "$HOME/release.tar.gz")" "$arch" >"$HOME/checksums"
    printf 'substituted archive\n' >"$HOME/corrupt.tar.gz"
    package_version() { echo 99.0.0; }
    get_arch() { printf '%s\n' "$arch"; }
    download() {
      printf '%s\n' "$1" >>"$HOME/downloads"
      case "$1" in
        */fzf_99.0.0_checksums.txt) cp "$HOME/checksums" "$2" ;;
        */fzf-99.0.0-linux_"$arch".tar.gz) cp "$HOME/${PAYLOAD:-release}.tar.gz" "$2" ;;
        *) return 90 ;;
      esac
    }
    run_fzf() {
      bash -euo pipefail -c 'source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; eval "$1"; source "$2"' _ \
        "$(declare -f package_version get_arch download)" "$temporary/fzf.sh"
    }
    if PAYLOAD=corrupt run_fzf; then
      printf 'Unverified fzf payload accepted\n' >&2
      exit 1
    fi
    [[ ! -e "$HOME/executed" && ! -e "$HOME/.fzf/bin/fzf" ]]
    run_fzf
    if grep -Fq vendor-installer-ran "$HOME/executed"; then
      printf 'Source installer unexpectedly executed\n' >&2
      exit 1
    fi
    [[ "$("$HOME/.fzf/bin/fzf" --version)" == 99.0.0 ]]
    ledger="$(cat "$DOTFILES_STATE_DIR/installed.tsv")"
    transfers="$(wc -l <"$HOME/downloads")"
    run_fzf
    [[ "$(cat "$DOTFILES_STATE_DIR/installed.tsv")" == "$ledger" ]]
    [[ "$(wc -l <"$HOME/downloads")" == "$transfers" ]]

    # A newer local binary remains active without downloading or adoption.
    printf '#!/bin/sh\necho 100.0.0\n' >"$HOME/.fzf/bin/fzf"
    run_fzf
    [[ "$("$HOME/.fzf/bin/fzf")" == 100.0.0 ]]
    [[ "$(cat "$DOTFILES_STATE_DIR/installed.tsv")" == "$ledger" ]]
    [[ "$(wc -l <"$HOME/downloads")" == "$transfers" ]]

    # Owned older binaries upgrade using the verified cache, without networking.
    printf '#!/bin/sh\necho 1.0.0\n' >"$HOME/.fzf/bin/fzf"
    record_install fzf 1.0.0 fixture "$HOME/.fzf/bin/fzf"
    run_fzf
    [[ "$("$HOME/.fzf/bin/fzf" --version)" == 99.0.0 ]]
    [[ "$(wc -l <"$HOME/downloads")" == "$transfers" ]]

    # An unowned symlink must never overwrite its destination, even if older.
    rm "$HOME/.fzf/bin/fzf"
    printf '#!/bin/sh\necho 1.0.0\n' >"$HOME/external-fzf"
    chmod +x "$HOME/external-fzf"
    ln -s "$HOME/external-fzf" "$HOME/.fzf/bin/fzf"
    run_fzf
    [[ -L "$HOME/.fzf/bin/fzf" && "$("$HOME/external-fzf")" == 1.0.0 ]]
    [[ "$(wc -l <"$HOME/downloads")" == "$transfers" ]]
  )
done
printf 'Managed font and fzf upgrade tests passed\n'
