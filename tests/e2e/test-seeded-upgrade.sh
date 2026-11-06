#!/usr/bin/env bash
# Synthetic previous-installation fixture: no host inventory or live downloads.
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
temporary="$(mktemp -d)"
started=$SECONDS
finish() {
  local status=$? log
  if [[ -n "${CI_RESULTS_DIR:-}" ]]; then
    mkdir -p "$CI_RESULTS_DIR/seeded-upgrade"
    for log in "$temporary"/*.log; do
      [[ ! -f "$log" ]] || cp "$log" "$CI_RESULTS_DIR/seeded-upgrade/"
    done
    printf '{"exit_code":%s,"duration_seconds":%s,"fixture":"synthetic-previous-install"}\n' \
      "$status" "$((SECONDS - started))" >"$CI_RESULTS_DIR/seeded-upgrade/summary.json"
  fi
  if [[ "$status" != 0 ]]; then
    for log in "$temporary"/*.log; do
      [[ ! -f "$log" ]] || tail -80 "$log"
    done
  fi
  rm -rf "$temporary"
}
trap finish EXIT
export HOME="$temporary/home" REAL_ROOT="$ROOT" FIXTURE_ROOT="$temporary"
export DOTFILES_STATE_DIR="$HOME/state" DOTFILES_DOWNLOAD_CACHE_DIR="$HOME/cache"
mkdir -p "$HOME/.local/bin" "$HOME/.config/dotfiles" "$temporary/source/scripts" "$temporary/app/bin"
export PATH="$HOME/.local/bin:$PATH"
printf 'private synthetic history\n' >"$HOME/.zsh_history"
printf 'export FIXTURE_LOCAL=1\n' >"$HOME/.config/dotfiles/local.zsh"
printf '#!/bin/sh\necho 1.0.0\n' >"$HOME/.local/bin/git-credential-manager"
chmod +x "$HOME/.local/bin/git-credential-manager"
printf '#!/bin/sh\n[ "$1" != --version ] || echo "NVIM v99.0.0"\nexit 0\n' >"$temporary/app/bin/nvim"
chmod +x "$temporary/app/bin/nvim"
tar -czf "$temporary/nvim.tar.gz" -C "$temporary" app
export FIXTURE_SHA
FIXTURE_SHA="$(sha256sum "$temporary/nvim.tar.gz" | cut -d' ' -f1)"
cat >"$temporary/source/scripts/lib.sh" <<'LIB'
DOTFILES_SOURCE_DIR="$REAL_ROOT"
source "$REAL_ROOT/scripts/lib.sh"
package_version() { printf '99.0.0\n'; }
package_metadata() { printf '%s\n' "$FIXTURE_SHA"; }
require_sudo() { :; }
is_ci() { return 0; }
is_native() { return 1; }
download() {
  printf 'fixture-download\n' >>"$FIXTURE_ROOT/downloads"
  cp "$FIXTURE_ROOT/nvim.tar.gz" "$2"
  [[ "${CORRUPT_TRANSFER:-0}" != 1 ]] || printf 'corrupt fixture\n' >"$2"
  [[ "${FAIL_TRANSFER:-0}" != 1 ]] || return 18
}
LIB
source "$ROOT/scripts/lib.sh"
old="$HOME/.local/share/dotfiles/tools/neovim/0.12.0"
mkdir -p "$old/bin"
printf '#!/bin/sh\necho "NVIM v0.12.0"\n' >"$old/bin/nvim"
chmod +x "$old/bin/nvim"
record_install nvim 0.12.0 fixture "$old"
managed_link "$old/bin/nvim" "$HOME/.local/bin/nvim" nvim 0.12.0
# Seed an unverifiable legacy GCM receipt: it must not authorize replacement.
printf 'git-credential-manager\t1.0.0\tlegacy\t%s\n' "$HOME/.local/bin/git-credential-manager" >>"$DOTFILES_STATE_DIR/installed.tsv"
before="$(sha256sum "$HOME/.zsh_history" "$HOME/.config/dotfiles/local.zsh" "$HOME/.local/bin/git-credential-manager")"
run_section() {
  DOTFILES_SOURCE_DIR="$temporary/source" bash "$ROOT/.chezmoiscripts/run_once_$1.sh.tmpl"
}
if FAIL_TRANSFER=1 run_section 07-install-neovim >"$temporary/interrupted.log" 2>&1; then
  printf 'Interrupted download unexpectedly succeeded\n' >&2
  exit 1
fi
[[ "$(nvim --version)" == 'NVIM v0.12.0' ]]
if CORRUPT_TRANSFER=1 run_section 07-install-neovim >"$temporary/corrupt.log" 2>&1; then
  printf 'Corrupt artifact unexpectedly succeeded\n' >&2
  exit 1
fi
[[ "$(nvim --version)" == 'NVIM v0.12.0' ]]
for pass in 1 2; do
  run_section 12-configure-system >"$temporary/system-$pass.log" 2>&1
  run_section 07-install-neovim >"$temporary/neovim-$pass.log" 2>&1
  [[ "$(nvim --version)" == 'NVIM v99.0.0' ]]
  [[ "$(sha256sum "$HOME/.zsh_history" "$HOME/.config/dotfiles/local.zsh" "$HOME/.local/bin/git-credential-manager")" == "$before" ]]
  if [[ "$pass" == 1 ]]; then
    state="$(sha256sum "$DOTFILES_STATE_DIR/installed.tsv" "$temporary/downloads")"
  else
    [[ "$(sha256sum "$DOTFILES_STATE_DIR/installed.tsv" "$temporary/downloads")" == "$state" ]]
  fi
done
# Newer and locally modified active runtimes must remain untouched too.
for version in 100.0.0 0.1.0; do
  printf '#!/bin/sh\necho "NVIM v%s"\n' "$version" >"$(readlink -f "$HOME/.local/bin/nvim")"
  runtime_before="$(sha256sum "$(readlink -f "$HOME/.local/bin/nvim")")"
  if run_section 07-install-neovim >"$temporary/preserved-$version.log" 2>&1; then
    [[ "$version" == 100.0.0 ]]
  else
    [[ "$version" == 0.1.0 ]]
    grep -Fq 'Preserving unowned or locally modified path' "$temporary/preserved-$version.log"
  fi
  [[ "$(sha256sum "$(readlink -f "$HOME/.local/bin/nvim")")" == "$runtime_before" ]]
done
bash "$ROOT/tests/test-bootstrap-safety.sh" "$ROOT" >"$temporary/owner-death.log" 2>&1
printf 'Seeded upgrade: interrupted transfer recovered; managed runtime upgraded; legacy tool, history and overlay preserved; second pass converged\n'
