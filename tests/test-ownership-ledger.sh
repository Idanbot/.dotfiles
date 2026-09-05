#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
export DOTFILES_STATE_DIR="$HOME/state"
export DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

mkdir -p "$HOME/.local/bin"
printf 'one\n' >"$HOME/.local/bin/demo"
record_install demo 1.0 test "$HOME/.local/bin/demo"
record_install demo 1.1 test "$HOME/.local/bin/demo"
[[ "$(wc -l <"$DOTFILES_STATE_DIR/installed.tsv")" -eq 1 ]]
grep -Fq $'demo\t1.1\ttest' "$DOTFILES_STATE_DIR/installed.tsv"
[[ "$(stat -c '%a' "$DOTFILES_STATE_DIR/installed.tsv")" == 600 ]]

record_install gemini 0.50.0 npm:@google/gemini-cli "$HOME/.local/share/npm/gemini"
forget_install gemini
! grep -q '^gemini' "$DOTFILES_STATE_DIR/installed.tsv"

record_install serena 1.6.1 uv:serena-agent "$HOME/.local/share/uv/tools/serena-agent"
"$DOTFILES_DIR/scripts/uninstall-tool.sh" --dry-run serena |
  grep -Fq 'would uv tool uninstall serena-agent'
forget_install serena

record_install graphify 0.9.38 uv:graphifyy "$HOME/.local/share/uv/tools/graphifyy"
"$DOTFILES_DIR/scripts/uninstall-tool.sh" --dry-run graphify |
  grep -Fq 'would uv tool uninstall graphifyy'
forget_install graphify

mkdir -p "$HOME/.agents/skills/ponytail"
record_install ponytail 4.9.0 agent-skill:DietrichGebert/ponytail "$HOME/.agents/skills/ponytail"
"$DOTFILES_DIR/scripts/uninstall-tool.sh" --dry-run ponytail |
  grep -Fq "would remove $HOME/.agents/skills/ponytail"
forget_install ponytail

record_install pix-optimizer 1.1.26 omp:@xynogen/pix-optimizer \
  "$HOME/.omp/plugins/node_modules/@xynogen/pix-optimizer"
"$DOTFILES_DIR/scripts/uninstall-tool.sh" --dry-run pix-optimizer |
  grep -Fq 'would omp plugin uninstall @xynogen/pix-optimizer'
forget_install pix-optimizer

"$DOTFILES_DIR/scripts/uninstall-tool.sh" --dry-run demo | grep -Fq 'would remove'
"$DOTFILES_DIR/scripts/uninstall-tool.sh" demo >/dev/null
[[ ! -e "$HOME/.local/bin/demo" ]]
! grep -q '^demo' "$DOTFILES_STATE_DIR/installed.tsv"

record_install distro 1 apt distro-package
"$DOTFILES_DIR/scripts/uninstall-tool.sh" distro >/dev/null
grep -q '^distro' "$DOTFILES_STATE_DIR/installed.tsv"
record_install python 3.14.6 uv-python 3.14.6
"$DOTFILES_DIR/scripts/uninstall-tool.sh" --dry-run python | grep -Fq 'would uv python uninstall 3.14.6'

printf '#!/bin/sh\nprintf "1.0\\n"\n' >"$HOME/good"
printf '#!/bin/sh\nexit 37\n' >"$HOME/bad"
install -m 755 "$HOME/good" "$HOME/.local/bin/self-demo"
managed_link "$HOME/.local/bin/self-demo" "$HOME/.local/bin/self-demo" self-demo 1
[[ ! -L "$HOME/.local/bin/self-demo" ]]
[[ "$("$HOME/.local/bin/self-demo")" == 1.0 ]]
install_managed_binary "$HOME/good" managed-demo 1 test 'managed-demo --version'
original="$(sha256sum "$HOME/.local/bin/managed-demo")"
if install_managed_binary "$HOME/bad" managed-demo 2 test 'managed-demo --version'; then
  printf 'bad binary smoke was ignored\n' >&2
  exit 1
fi
[[ "$(sha256sum "$HOME/.local/bin/managed-demo")" == "$original" ]]
(
  mv() {
    if [[ "${*: -1}" == "$DOTFILES_STATE_DIR/installed.tsv" ]]; then
      return 1
    fi
    command mv "$@"
  }
  if install_managed_binary "$HOME/bad" managed-demo 2 test; then
    printf 'ledger failure accepted replacement\n' >&2
    exit 1
  fi
)
[[ "$(sha256sum "$HOME/.local/bin/managed-demo")" == "$original" ]]
assert_owned_target "$HOME/.local/bin/managed-demo"
printf 'user modified\n' >"$HOME/.local/bin/managed-demo"
if install_managed_binary "$HOME/good" managed-demo 3 test; then
  printf 'local modification overwritten\n' >&2
  exit 1
fi
if "$DOTFILES_DIR/scripts/uninstall-tool.sh" managed-demo >/dev/null 2>&1; then
  printf 'modified tool removed\n' >&2
  exit 1
fi
grep -Fxq 'user modified' "$HOME/.local/bin/managed-demo"
printf 'unowned\n' >"$HOME/.local/bin/unowned"
if managed_link "$HOME/good" "$HOME/.local/bin/unowned" demo 1; then
  printf 'unowned link destination replaced\n' >&2
  exit 1
fi
grep -Fxq unowned "$HOME/.local/bin/unowned"

mkdir -p "$HOME/tree-source/bin"
install -m 755 "$HOME/good" "$HOME/tree-source/bin/probe"
install_managed_tree "$HOME/tree-source" "$HOME/.local/tree" tree 1 test bin/probe
install -m 755 "$HOME/bad" "$HOME/tree-source/bin/probe"
if install_managed_tree "$HOME/tree-source" "$HOME/.local/tree" tree 2 test bin/probe; then
  printf 'failed tree smoke replaced the runtime\n' >&2
  exit 1
fi
[[ "$("$HOME/.local/tree/bin/probe")" == 1.0 ]]
mkdir -p "$HOME/.local/owned-parent"
printf 'keep\n' >"$HOME/.local/owned-parent/tool"
record_install redirected 1 test "$HOME/.local/owned-parent/tool"
mv "$HOME/.local/owned-parent" "$HOME/relocated-parent"
ln -s "$HOME/relocated-parent" "$HOME/.local/owned-parent"
if "$DOTFILES_DIR/scripts/uninstall-tool.sh" redirected >/dev/null 2>&1; then
  printf 'redirected ancestor allowed removal\n' >&2
  exit 1
fi
grep -Fxq keep "$HOME/relocated-parent/tool"
managed_link "$HOME/good" "$HOME/.local/bin/review-link" review-link 1
(
  record_install() { return 1; }
  if managed_link "$HOME/bad" "$HOME/.local/bin/review-link" review-link 2; then
    exit 1
  fi
  [[ "$(readlink "$HOME/.local/bin/review-link")" == "$HOME/good" ]]
)
forget_install review-link
if managed_link "$HOME/bad" "$HOME/.local/bin/review-link" review-link 2; then
  printf 'stale ownership stamp allowed replacement\n' >&2
  exit 1
fi
for index in {1..12}; do
  record_install "parallel-$index" 1 apt "package-$index" &
done
wait
[[ "$(grep -c '^parallel-' "$DOTFILES_STATE_DIR/installed.tsv")" == 12 ]]

printf 'Ownership ledger test passed\n'
