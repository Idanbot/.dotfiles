#!/usr/bin/env bash
# Download, checksum, install, and execute every shared GitHub helper shape.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
export DOTFILES_BIN_DIR="$TMP_HOME/bin"
export DOTFILES_STATE_DIR="$TMP_HOME/state"
export DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
mkdir -p "$DOTFILES_BIN_DIR"
export PATH="$DOTFILES_BIN_DIR:$PATH"

# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

ARCH="$(get_arch)"
case "$ARCH" in
  amd64)
    RELEASE_ARCH=x86_64
    EZA_SHA=0c38665440226cd8bef5d1d4f3bc6ff77c927fb0d68b752739105db7ab5b358d
    OMP_ARCH=x64
    OMP_SHA=c7a2fa328c965131c0d0ef62a07a4fe63306ed1b7a90fbbb924c75605c68d38a
    ;;
  arm64)
    RELEASE_ARCH=aarch64
    EZA_SHA=366e8430225f9955c3dc659b452150c169894833ccfef455e01765e265a3edda
    OMP_ARCH=arm64
    OMP_SHA=6bb8d76fa25ebea08b2ce87a79387c1dd0bcbff5564ef5bc79f2595a870a3a68
    ;;
  *)
    printf 'Unsupported smoke architecture: %s\n' "$ARCH" >&2
    exit 1
    ;;
esac

EZA_VERSION="$(package_version core eza 0.23.4)"
install_github_archive eza eza-community/eza "v$EZA_VERSION" \
  "eza_${RELEASE_ARCH}-unknown-linux-gnu.tar.gz" ./eza \
  "sha256:$EZA_SHA" \
  'eza --version'

LAZYGIT_VERSION="$(package_version core lazygit 0.63.0)"
install_github_archive lazygit jesseduffield/lazygit "v$LAZYGIT_VERSION" \
  "lazygit_{version}_linux_${RELEASE_ARCH}.tar.gz" lazygit \
  'https://github.com/jesseduffield/lazygit/releases/download/{tag}/checksums.txt' \
  'lazygit --version'

LAZYDOCKER_VERSION="$(package_version core lazydocker 0.25.2)"
install_github_archive lazydocker jesseduffield/lazydocker "v$LAZYDOCKER_VERSION" \
  "lazydocker_{version}_Linux_${RELEASE_ARCH}.tar.gz" lazydocker \
  'https://github.com/jesseduffield/lazydocker/releases/download/{tag}/checksums.txt' \
  'lazydocker --version'

SOPS_VERSION="$(package_version core sops 3.13.2)"
install_github_binary sops getsops/sops "v$SOPS_VERSION" "sops-{tag}.linux.${ARCH}" sops \
  'https://github.com/getsops/sops/releases/download/{tag}/sops-{tag}.checksums.txt' \
  'sops --version'

TEALDEER_VERSION="$(package_version core tealdeer 1.8.1)"
install_github_binary tldr dbrgn/tealdeer "v$TEALDEER_VERSION" \
  "tealdeer-linux-${RELEASE_ARCH}-musl" tldr \
  "https://github.com/dbrgn/tealdeer/releases/download/{tag}/tealdeer-linux-${RELEASE_ARCH}-musl.sha256" \
  'tldr --version'

STARSHIP_VERSION="$(package_version core starship 1.26.0)"
install_github_archive starship starship/starship "v$STARSHIP_VERSION" \
  "starship-${RELEASE_ARCH}-unknown-linux-gnu.tar.gz" starship \
  "https://github.com/starship/starship/releases/download/{tag}/starship-${RELEASE_ARCH}-unknown-linux-gnu.tar.gz.sha256" \
  'starship --version'

OMP_VERSION="$(package_version ai_tools omp 16.4.0)"
install_github_binary omp can1357/oh-my-pi "v$OMP_VERSION" "omp-linux-$OMP_ARCH" omp \
  "sha256:$OMP_SHA" 'omp --version'

for binary in eza lazygit lazydocker sops tldr starship omp; do
  "$DOTFILES_BIN_DIR/$binary" --version >/dev/null
done

[[ "$(wc -l <"$DOTFILES_STATE_DIR/installed.tsv")" -ge 7 ]]
printf 'GitHub release tool smoke passed\n'
