#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
export PATH="$HOME/bin:$PATH"
mkdir -p "$HOME/.config/tmuxp" "$HOME/bin" "$HOME/project with spaces"
cp "$DOTFILES_DIR/dot_config/tmuxp/agent-workspace.yaml" "$HOME/.config/tmuxp/agent-workspace.yaml"
printf '#!/bin/sh\nexit 0\n' >"$HOME/bin/uvx"
printf '#!/bin/sh\nexit 0\n' >"$HOME/bin/tmux"
chmod +x "$HOME/bin/uvx" "$HOME/bin/tmux"

rendered="$($DOTFILES_DIR/dot_local/bin/executable_dot-workspace "$HOME/project with spaces" --name test-agents --print)"
grep -Fq 'session_name: "test-agents"' <<<"$rendered"
grep -Fq "start_directory: \"$HOME/project with spaces\"" <<<"$rendered"
for agent in codex antigravity claude opencode omp; do
  grep -Fq "dot-agent-launch $agent" <<<"$rendered"
done
printf '%s\n' "$rendered" | yq . >/dev/null

printf 'Agent workspace test passed\n'
