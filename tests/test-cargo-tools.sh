#!/usr/bin/env bash
# test-cargo-tools.sh — Install and smoke-test Rust CLI tools
set -euo pipefail

TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export CARGO_HOME="$TMP_HOME/.cargo"
export RUSTUP_HOME="$TMP_HOME/.rustup"
export PATH="$CARGO_HOME/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  # shellcheck source=/dev/null
  source "$CARGO_HOME/env"
fi

cargo install du-dust xh
dust --version
xh --version

echo "cargo tool install smoke passed"
