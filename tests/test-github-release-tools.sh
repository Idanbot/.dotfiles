#!/usr/bin/env bash
# test-github-release-tools.sh — Download/install smoke for GitHub-release tools
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export DOTFILES_BIN_DIR="$TMP_HOME/bin"
mkdir -p "$DOTFILES_BIN_DIR"
export PATH="$DOTFILES_BIN_DIR:$PATH"

# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

is_installed() {
  [[ -x "$DOTFILES_BIN_DIR/$1" ]]
}

ARCH=$(get_arch)
if [[ "$ARCH" == "amd64" ]]; then
  LG_ARCH="x86_64"
else
  LG_ARCH="$ARCH"
fi
install_github_archive lazygit jesseduffield/lazygit latest "lazygit_{version}_Linux_${LG_ARCH}.tar.gz" lazygit
LAZYDOCKER_VERSION=$(package_version core lazydocker 0.25.2)
install_github_archive lazydocker jesseduffield/lazydocker "v${LAZYDOCKER_VERSION#v}" "lazydocker_{version}_Linux_x86_64.tar.gz" lazydocker
install_github_binary sops getsops/sops latest "sops-{tag}.linux.${ARCH}" sops
TEALDEER_VERSION=$(package_version core tealdeer 1.6.1)
install_github_binary tldr dbrgn/tealdeer "v${TEALDEER_VERSION#v}" "tealdeer-linux-x86_64-musl" tldr

"$DOTFILES_BIN_DIR/lazygit" --version
"$DOTFILES_BIN_DIR/lazydocker" --version
"$DOTFILES_BIN_DIR/sops" --version
"$DOTFILES_BIN_DIR/tldr" --version

echo "GitHub-release tool smoke passed"
