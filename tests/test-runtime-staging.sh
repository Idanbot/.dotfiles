#!/usr/bin/env bash
# Exercise the real Go/npm installer blocks with offline runtime fixtures.
set -euo pipefail
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
export HOME="$temporary/home" DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
export DOTFILES_STATE_DIR="$HOME/state"
mkdir -p "$HOME/.local/bin" "$HOME/go/bin" "$HOME/node/bin"
source "$DOTFILES_DIR/scripts/lib.sh"
printf '#!/bin/sh\necho "go version go1.99.0 linux/amd64"\n' >"$HOME/go/bin/go"
cp "$HOME/go/bin/go" "$HOME/go/bin/gofmt"
chmod +x "$HOME/go/bin/"*
ln -s "$HOME/go/bin/go" "$HOME/.local/bin/go"
export PATH="$HOME/.local/bin:$PATH"
awk '/^GO_VERSION=/ { block = 1 } /^RUST_CHANNEL=/ { exit } block' \
  "$DOTFILES_DIR/.chezmoiscripts/run_once_04-install-languages.sh.tmpl" >"$temporary/go.sh"
source "$temporary/go.sh"
source "$temporary/go.sh"
[[ "$(readlink "$HOME/.local/bin/go")" == "$HOME/go/bin/go" ]]
[[ "$(go version)" == 'go version go1.99.0 linux/amd64' ]]

export NODE_ROOT="$HOME/node" NODE_VERSION=26.0.0
EXPECTED_NPM="$(package_version languages npm 12.0.1)"
export EXPECTED_NPM
printf '#!/bin/sh\necho v26.0.0\n' >"$NODE_ROOT/bin/node"
cat >"$NODE_ROOT/bin/npm" <<'NPM'
#!/bin/sh
root=$(dirname "$0")/..
if [ "$1" = --version ]; then
  cat "$root/npm-version"
else
  printf '%s\n' "$EXPECTED_NPM" >"$root/npm-version"
  if [ "${FAIL_NPM:-0}" = 1 ]; then exit 37; fi
  mkdir -p "$root/lib/node_modules/npm"
fi
NPM
chmod +x "$NODE_ROOT/bin/"*
printf '11.0.0\n' >"$NODE_ROOT/npm-version"
record_install node "$NODE_VERSION" node-dist "$NODE_ROOT"
awk '/^NPM_VERSION=/ { block = 1 } /^for binary in node / { exit } block' \
  "$DOTFILES_DIR/.chezmoiscripts/run_once_04-install-languages.sh.tmpl" >"$temporary/npm.sh"
if FAIL_NPM=1 bash -c 'set -euo pipefail; source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; source "$1"' _ "$temporary/npm.sh"; then
  printf 'failed npm update accepted\n' >&2
  exit 1
fi
[[ "$("$NODE_ROOT/bin/npm" --version)" == 11.0.0 ]]
assert_owned_target "$NODE_ROOT"
bash -c 'set -euo pipefail; source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; source "$1"' _ "$temporary/npm.sh"
[[ "$("$NODE_ROOT/bin/npm" --version)" == "$EXPECTED_NPM" ]]
assert_owned_target "$NODE_ROOT"
printf 'Runtime staging test passed\n'
