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
export DOTFILES_AGENT_REGISTRY="$TMP_HOME/.config/dotfiles/agents.yaml"
mkdir -p "$DOTFILES_BIN_DIR"
export PATH="$DOTFILES_BIN_DIR:$PATH"

# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

ARCH="$(get_arch)"
case "$ARCH" in
  amd64)
    RELEASE_ARCH=x86_64
    OMP_ARCH=x64
    HERDR_ARCH=x86_64
    ;;
  arm64)
    RELEASE_ARCH=aarch64
    OMP_ARCH=arm64
    HERDR_ARCH=aarch64
    ;;
  *)
    printf 'Unsupported smoke architecture: %s\n' "$ARCH" >&2
    exit 1
    ;;
esac
EZA_SHA="$(package_metadata core eza "sha256_$ARCH")"
OMP_SHA="$(package_metadata ai_tools omp "sha256_$ARCH")"
HERDR_SHA="$(package_metadata terminal herdr "sha256_$ARCH")"

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

HERDR_VERSION="$(package_version terminal herdr 0.7.4)"
install_github_binary herdr ogulcancelik/herdr "v$HERDR_VERSION" \
  "herdr-linux-$HERDR_ARCH" herdr "sha256:$HERDR_SHA" 'herdr --version'

for binary in eza lazygit lazydocker sops tldr starship omp herdr; do
  "$DOTFILES_BIN_DIR/$binary" --version >/dev/null
done

[[ "$(wc -l <"$DOTFILES_STATE_DIR/installed.tsv")" -ge 8 ]]

export HERDR_CONFIG_PATH="$DOTFILES_DIR/dot_config/herdr/config.toml"
export SHELL=/bin/bash
herdr server >"$TMP_HOME/herdr-server.out" 2>&1 &
server_pid=$!
for _ in {1..100}; do
  herdr workspace list >/dev/null 2>&1 && break
  sleep 0.1
done
herdr workspace list >/dev/null

mkdir -p "$(dirname "$DOTFILES_AGENT_REGISTRY")" "$HOME/.config/tmuxp" "$HOME/workspace-smoke"
cp "$DOTFILES_DIR/agents.yaml" "$DOTFILES_AGENT_REGISTRY"
cp "$DOTFILES_DIR/dot_config/tmuxp/agent-workspace.yaml" "$HOME/.config/tmuxp/agent-workspace.yaml"
for agent in codex antigravity claude opencode omp; do
  sed -i "s/command: $agent/command: missing-$agent/" "$DOTFILES_AGENT_REGISTRY"
done
ln -s "$DOTFILES_DIR/dot_local/bin/executable_dot-agent-launch" "$DOTFILES_BIN_DIR/dot-agent-launch"

HERDR_ENV=1 "$DOTFILES_DIR/dot_local/bin/executable_dot-workspace" \
  "$HOME/workspace-smoke" --name release-smoke
HERDR_ENV=1 "$DOTFILES_DIR/dot_local/bin/executable_dot-workspace" \
  "$HOME/workspace-smoke" --name release-smoke

workspaces="$(herdr workspace list)"
[[ "$(jq '[.result.workspaces[] | select(.label == "release-smoke")] | length' <<<"$workspaces")" -eq 1 ]]
workspace_id="$(jq -r '.result.workspaces[] | select(.label == "release-smoke") | .workspace_id' <<<"$workspaces")"
workspace="$(herdr workspace get "$workspace_id")"
[[ "$(jq -r '.result.workspace.tab_count' <<<"$workspace")" -eq 6 ]]
[[ "$(jq -r '.result.workspace.pane_count' <<<"$workspace")" -eq 6 ]]

herdr server stop >/dev/null
wait "$server_pid" 2>/dev/null || true
printf 'GitHub release tool smoke passed\n'
