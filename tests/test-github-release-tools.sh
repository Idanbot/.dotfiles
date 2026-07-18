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
    EZA_SHA=0c38665440226cd8bef5d1d4f3bc6ff77c927fb0d68b752739105db7ab5b358d
    OMP_ARCH=x64
    OMP_SHA=c7a2fa328c965131c0d0ef62a07a4fe63306ed1b7a90fbbb924c75605c68d38a
    HERDR_ARCH=x86_64
    HERDR_SHA=bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059
    ;;
  arm64)
    RELEASE_ARCH=aarch64
    EZA_SHA=366e8430225f9955c3dc659b452150c169894833ccfef455e01765e265a3edda
    OMP_ARCH=arm64
    OMP_SHA=6bb8d76fa25ebea08b2ce87a79387c1dd0bcbff5564ef5bc79f2595a870a3a68
    HERDR_ARCH=aarch64
    HERDR_SHA=544e0002de42806d1ab64ccdef3a7e7414f24717b0b6b022bc9e57d2eefd26a2
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
