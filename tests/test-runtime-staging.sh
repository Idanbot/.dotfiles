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
export PATH="$NODE_ROOT/bin:$PATH"
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
# Execute the real application installers with offline archives and failed probes.
mkdir -p "$temporary/app/bin"
printf '#!/bin/sh\nexit 37\n' >"$temporary/app/bin/nvim"
cp "$temporary/app/bin/nvim" "$temporary/app/bin/kitty"
cp "$temporary/app/bin/nvim" "$temporary/app/bin/kitten"
chmod +x "$temporary/app/bin/"*
tar -czf "$temporary/nvim.tar.gz" -C "$temporary" app
tar -cJf "$temporary/kitty.txz" -C "$temporary/app" .
for application in nvim kitty; do
  if [[ "$application" == nvim ]]; then
    target="$HOME/.local/share/dotfiles/tools/neovim/99.0.0"
    installer="$DOTFILES_DIR/.chezmoiscripts/run_once_07-install-neovim.sh.tmpl"
    archive="$temporary/nvim.tar.gz"
  else
    target="$HOME/.local/kitty.app"
    installer="$DOTFILES_DIR/scripts/install-kitty.sh"
    archive="$temporary/kitty.txz"
  fi
  mkdir -p "$target/bin"
  printf '#!/bin/sh\necho 0.0.0\n' >"$target/bin/$application"
  chmod +x "$target/bin/$application"
  record_install "$application" 0 test "$target"
  # Omit only library loading so the real installer can use fixture downloads.
  sed '/^source .*scripts\/lib.sh/d' "$installer" >"$temporary/installer.sh"
  for failure in probe extraction; do
    (
      package_version() { printf '99.0.0\n'; }
      package_metadata() { printf 'fixture\n'; }
      download_verified() {
        if [[ "$failure" == extraction ]]; then
          printf 'invalid archive\n' >"$2"
        else
          cp "$archive" "$2"
        fi
      }
      export -f package_version package_metadata download_verified
      export failure archive
      if bash -c 'source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; eval "$1"; script="$2"; set --; source "$script"' _ \
        "$(declare -f package_version package_metadata download_verified)" "$temporary/installer.sh"; then
        printf '%s accepted %s failure\n' "$application" "$failure" >&2
        exit 1
      fi
    )
    [[ "$("$target/bin/$application")" == 0.0.0 ]]
    assert_owned_target "$target"
  done
done

# Exercise the complete Neovim section, not only the publication helper.
mkdir -p "$temporary/good-nvim/bin"
printf '#!/bin/sh\necho "NVIM v99.0.0"\n' >"$temporary/good-nvim/bin/nvim"
chmod +x "$temporary/good-nvim/bin/nvim"
tar -czf "$temporary/good-nvim.tar.gz" -C "$temporary" good-nvim
mkdir -p "$temporary/broken-nvim/bin"
printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "NVIM v99.0.0"; else exit 37; fi\n' >"$temporary/broken-nvim/bin/nvim"
chmod +x "$temporary/broken-nvim/bin/nvim"
tar -czf "$temporary/broken-nvim.tar.gz" -C "$temporary" broken-nvim
sed '/^source .*scripts\/lib.sh/d' \
  "$DOTFILES_DIR/.chezmoiscripts/run_once_07-install-neovim.sh.tmpl" >"$temporary/neovim.sh"
for scenario in missing legacy modified newer unknown owned approved approved-broken approved-redirected; do
  (
    export HOME="$temporary/neovim-$scenario" DOTFILES_STATE_DIR="$temporary/state-$scenario"
    mkdir -p "$HOME/.local/bin"
    source "$DOTFILES_DIR/scripts/lib.sh"
    printf '#!/bin/sh\necho "NVIM v0.12.4"\n' >"$HOME/.local/bin/nvim"
    chmod +x "$HOME/.local/bin/nvim"
    case "$scenario" in
      legacy)
        record_install nvim 0.12.4 fixture "$HOME/.local/bin/nvim"
        rm "$(ownership_stamp "$HOME/.local/bin/nvim")"
        ;;
      modified)
        record_install nvim 0.12.4 fixture "$HOME/.local/bin/nvim"
        printf '# local edit\n' >>"$HOME/.local/bin/nvim"
        ;;
      newer) sed -i s/0.12.4/100.0.0/ "$HOME/.local/bin/nvim" ;;
      unknown) printf '#!/bin/sh\nexit 37\n' >"$HOME/.local/bin/nvim" ;;
      owned) record_install nvim 0.12.4 fixture "$HOME/.local/bin/nvim" ;;
      approved | approved-broken | approved-redirected) export DOTFILES_REPLACE_BINARIES=nvim ;;
    esac
    if [[ "$scenario" == approved-redirected ]]; then
      mv "$HOME/.local/bin" "$HOME/external-bin"
      ln -s "$HOME/external-bin" "$HOME/.local/bin"
    fi
    cp -p "$HOME/.local/bin/nvim" "$HOME/original"
    [[ "$scenario" != missing ]] || rm "$HOME/.local/bin/nvim"
    export NVIM_FIXTURE="$temporary/good-nvim.tar.gz" NVIM_CALLS="$HOME/downloads"
    [[ "$scenario" != approved-broken ]] || NVIM_FIXTURE="$temporary/broken-nvim.tar.gz"
    package_version() { printf '99.0.0\n'; }
    package_metadata() { printf 'fixture\n'; }
    download_verified() {
      printf 'download\n' >>"$NVIM_CALLS"
      cp "$NVIM_FIXTURE" "$2"
    }
    status=0
    bash -c 'source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; eval "$1"; source "$2"' _ \
      "$(declare -f package_version package_metadata download_verified)" "$temporary/neovim.sh" >"$HOME/output" 2>&1 || status=$?
    if [[ "$scenario" == approved-broken || "$scenario" == approved-redirected ]]; then
      [[ "$status" -ne 0 ]]
      cmp "$HOME/original" "$HOME/.local/bin/nvim"
      [[ ! -e "$DOTFILES_STATE_DIR/binary-backups" ]]
      exit 0
    fi
    [[ "$status" == 0 ]]
    case "$scenario" in
      missing | owned | approved)
        [[ -f "$NVIM_CALLS" && -L "$HOME/.local/bin/nvim" ]]
        target_is_owned "$HOME/.local/bin/nvim"
        [[ "$(nvim --version)" == 'NVIM v99.0.0' ]]
        bash -c 'source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; eval "$1"; source "$2"' _ \
          "$(declare -f package_version package_metadata download_verified)" "$temporary/neovim.sh" >>"$HOME/output"
        [[ "$(wc -l <"$NVIM_CALLS")" == 1 ]]
        if [[ "$scenario" == approved ]]; then
          backup="$(find "$DOTFILES_STATE_DIR/binary-backups" -type f -name nvim)"
          cmp "$HOME/original" "$backup"
          [[ "$(stat -c %a "$(dirname "$backup")")" == 700 ]]
        fi
        ;;
      *)
        cmp "$HOME/original" "$HOME/.local/bin/nvim"
        [[ ! -e "$NVIM_CALLS" ]]
        ;;
    esac
  )
done

# Real uv publication records both the environment and command, converges, and
# refuses a directory modified between the initial decision and the force call.
(
  export HOME="$temporary/uv-home" DOTFILES_STATE_DIR="$temporary/uv-state"
  export DOTFILES_VERSION_PLAN="$temporary/uv-versions.json"
  printf '{"tools":{}}\n' >"$DOTFILES_VERSION_PLAN"
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
  source "$DOTFILES_DIR/scripts/install-uv-tool.sh"
  export UV_FIXTURE_VERSION=1.0.0 UV_FIXTURE_CALLS="$temporary/uv-calls"
  uv() {
    if [[ "$*" == 'tool dir' ]]; then
      printf '%s\n' "$HOME/.local/share/uv/tools"
      return
    fi
    printf '%s\n' "$*" >>"$UV_FIXTURE_CALLS"
    local root="$HOME/.local/share/uv/tools/fixture-package"
    mkdir -p "$root/bin"
    printf '#!/bin/sh\necho %s\n' "$UV_FIXTURE_VERSION" >"$root/bin/fixture-cli"
    chmod +x "$root/bin/fixture-cli"
    ln -sfn "$root/bin/fixture-cli" "$HOME/.local/bin/fixture-cli"
  }
  install_uv_tool fixture-cli fixture-package "$UV_FIXTURE_VERSION"
  assert_owned_target "$HOME/.local/share/uv/tools/fixture-package"
  assert_owned_target "$HOME/.local/bin/fixture-cli"
  before="$(managed_target_digest "$HOME/.local/share/uv/tools/fixture-package")"
  install_uv_tool fixture-cli fixture-package "$UV_FIXTURE_VERSION"
  [[ "$(wc -l <"$UV_FIXTURE_CALLS")" == 1 ]]
  [[ "$(managed_target_digest "$HOME/.local/share/uv/tools/fixture-package")" == "$before" ]]
  UV_FIXTURE_VERSION=1.0.1
  install_uv_tool fixture-cli fixture-package "$UV_FIXTURE_VERSION" 3.13
  [[ "$(fixture-cli --version)" == 1.0.1 ]]
  [[ "$(wc -l <"$UV_FIXTURE_CALLS")" == 2 ]]
  managed_operation_lock() {
    printf 'local edit during lock acquisition\n' >"$HOME/.local/share/uv/tools/fixture-package/modified"
  }
  install_uv_tool fixture-cli fixture-package 1.0.2
  [[ "$(wc -l <"$UV_FIXTURE_CALLS")" == 2 ]]
  [[ -f "$HOME/.local/share/uv/tools/fixture-package/modified" ]]
  [[ "$(fixture-cli --version)" == 1.0.1 ]]
)
printf 'Runtime staging test passed\n'
