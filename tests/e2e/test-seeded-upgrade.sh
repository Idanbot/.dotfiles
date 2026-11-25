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
export ZDOTDIR="$HOME" XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME/.local/bin" "$HOME/.config/dotfiles" "$HOME/.config/chezmoi" \
  "$HOME/.fzf/bin" "$HOME/.oh-my-zsh" "$HOME/.agents/skills/ponytail" \
  "$temporary/source/scripts" "$temporary/app/bin"
export PATH="$HOME/.local/bin:$PATH"
printf 'private synthetic history\n' >"$HOME/.zsh_history"
printf 'export FIXTURE_LOCAL=1\n' >"$HOME/.config/dotfiles/local.zsh"
printf 'export FIXTURE_SHELL_EDIT=kept\n' >"$HOME/.zshrc"
printf 'source <(fzf --zsh)\n' >"$HOME/.fzf.zsh"
ln -s /usr/bin/fzf "$HOME/.fzf/bin/fzf"
printf '# Offline Oh My Zsh fixture\n' >"$HOME/.oh-my-zsh/oh-my-zsh.sh"
printf '# Previously installed synthetic skill\n' >"$HOME/.agents/skills/ponytail/SKILL.md"
cat >"$HOME/.config/chezmoi/chezmoi.yaml" <<'EOF'
data:
  name: Test User
  email: test@example.invalid
  sessionizer_dirs: "~/Code ~/Scripts"
  is_wsl: true
EOF
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
# shellcheck source=../../scripts/conflicts.sh
source "$ROOT/scripts/conflicts.sh"
old="$HOME/.local/share/dotfiles/tools/neovim/0.12.0"
mkdir -p "$old/bin"
printf '#!/bin/sh\necho "NVIM v0.12.0"\n' >"$old/bin/nvim"
chmod +x "$old/bin/nvim"
export DOTFILES_VERSION_PLAN="$temporary/versions.json"
jq -n --arg nvim "$HOME/.local/bin/nvim" --arg gcm "$HOME/.local/bin/git-credential-manager" \
  '{schema:1,tools:{"editor.neovim":{decision:{schema:1,operation:"update",target:"99.0.0",evidence:{path:$nvim}}},"system.git_credential_manager":{decision:{schema:1,operation:"preserve",target:"99.0.0",evidence:{path:$gcm}}}}}' >"$DOTFILES_VERSION_PLAN"
run_section() {
  DOTFILES_SOURCE_DIR="$temporary/source" bash "$ROOT/.chezmoiscripts/run_once_$1.sh.tmpl"
}
# Exercise the same old Neovim once without a receipt before testing an owned upgrade.
ln -s "$old/bin/nvim" "$HOME/.local/bin/nvim"
run_section 07-install-neovim >"$temporary/neovim-legacy.log" 2>&1
[[ "$(nvim --version)" == 'NVIM v0.12.0' && ! -e "$temporary/downloads" ]]
rm "$HOME/.local/bin/nvim"
record_install nvim 0.12.0 fixture "$old"
managed_link "$old/bin/nvim" "$HOME/.local/bin/nvim" nvim 0.12.0
# Seed an unverifiable legacy GCM receipt: it must not authorize replacement.
printf 'git-credential-manager\t1.0.0\tlegacy\t%s\n' "$HOME/.local/bin/git-credential-manager" >>"$DOTFILES_STATE_DIR/installed.tsv"
preserved=("$HOME/.zsh_history" "$HOME/.config/dotfiles/local.zsh"
  "$HOME/.local/bin/git-credential-manager" "$HOME/.agents/skills/ponytail/SKILL.md")
before="$(sha256sum "${preserved[@]}")"

migrate_shell() {
  local status=0 fzf_status
  if [[ "$1" == 0 ]]; then
    chezmoi apply --source="$ROOT" --exclude=scripts,externals --force "$HOME/.fzf.zsh"
  else
    fzf_status="$(chezmoi status --source="$ROOT" --exclude=scripts,externals "$HOME/.fzf.zsh")"
    [[ -z "$fzf_status" ]] || return 1
  fi
  dotfiles_conflict_merge_append "$ROOT" .zshrc || status=$?
  [[ "$status" == "$1" ]]
}
check_login_shell() {
  script -qec 'zsh -dil "$FIXTURE_ROOT/check-login.zsh" 2>"$HOME/startup.err"' /dev/null </dev/null
  cat "$HOME/startup.err"
  [[ ! -s "$HOME/startup.err" ]]
}
cat >"$temporary/check-login.zsh" <<'EOF'
[[ "$FIXTURE_LOCAL" == 1 && "$FIXTURE_SHELL_EDIT" == kept ]] &&
  [[ ${commands[fzf]} == "$HOME/.fzf/bin/fzf" ]] &&
  [[ $(bindkey "\C-r") == *" fzf-history-widget" ]]
EOF
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
  if [[ "$pass" == 1 ]]; then
    migrate_shell 0 >"$temporary/config-$pass.log" 2>&1
  else
    migrate_shell 3 >"$temporary/config-$pass.log" 2>&1
  fi
  check_login_shell >"$temporary/login-$pass.log" 2>&1
  run_section 12-configure-system >"$temporary/system-$pass.log" 2>&1
  run_section 07-install-neovim >"$temporary/neovim-$pass.log" 2>&1
  [[ "$(nvim --version)" == 'NVIM v99.0.0' ]]
  [[ "$(sha256sum "${preserved[@]}")" == "$before" ]]
  observed="$(sha256sum "$DOTFILES_STATE_DIR/installed.tsv" "$temporary/downloads" "$HOME/.zshrc" "$HOME/.fzf.zsh")"
  if [[ "$pass" == 1 ]]; then
    state="$observed"
  else
    [[ "$observed" == "$state" ]]
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
printf 'Seeded upgrade: login shell works; owned runtime upgraded; legacy tools and customizations preserved; second pass converged\n'
