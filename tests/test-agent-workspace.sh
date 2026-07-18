#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
export PATH="$HOME/bin:$PATH"
export DOTFILES_AGENT_REGISTRY="$HOME/.config/dotfiles/agents.yaml"
mkdir -p "$HOME/.config/tmuxp" "$HOME/.config/dotfiles" "$HOME/bin" "$HOME/project with spaces"
cp "$DOTFILES_DIR/dot_config/tmuxp/agent-workspace.yaml" "$HOME/.config/tmuxp/agent-workspace.yaml"
cp "$DOTFILES_DIR/agents.yaml" "$DOTFILES_AGENT_REGISTRY"
printf '#!/bin/sh\nexit 0\n' >"$HOME/bin/uvx"
printf '#!/bin/sh\nexit 0\n' >"$HOME/bin/tmux"
chmod +x "$HOME/bin/uvx" "$HOME/bin/tmux"

WORKSPACE="$DOTFILES_DIR/dot_local/bin/executable_dot-workspace"
AGENT_LAUNCH="$DOTFILES_DIR/dot_local/bin/executable_dot-agent-launch"

rendered="$(env -u HERDR_ENV -u TMUX "$WORKSPACE" "$HOME/project with spaces" \
  --backend tmux --name test-agents --print)"
grep -Fq 'session_name: "test-agents"' <<<"$rendered"
grep -Fq "start_directory: \"$HOME/project with spaces\"" <<<"$rendered"
[[ "$(yq -r '.options.prefix' <<<"$rendered")" == C-s ]]
for agent in codex antigravity claude opencode omp; do
  grep -Fq "dot-agent-launch $agent" <<<"$rendered"
done
printf '%s\n' "$rendered" | yq . >/dev/null

set +e
HERDR_ENV=1 "$WORKSPACE" "$HOME/project with spaces" --backend tmux --print \
  >"$HOME/nested.out" 2>"$HOME/nested.err"
status=$?
set -e
[[ "$status" -eq 2 ]]
grep -Fq 'Refusing to launch tmux inside Herdr' "$HOME/nested.err"

nested="$(HERDR_ENV=1 "$WORKSPACE" "$HOME/project with spaces" \
  --backend tmux --allow-nested --print)"
[[ "$(yq -r '.options.prefix' <<<"$nested")" == C-b ]]

herdr_plan="$(HERDR_ENV=1 "$WORKSPACE" "$HOME/project with spaces" \
  --name test-agents --print)"
[[ "$(jq -r '.backend' <<<"$herdr_plan")" == herdr ]]
[[ "$(jq -r '.workspace' <<<"$herdr_plan")" == test-agents ]]
[[ "$(jq -r '.agents | length' <<<"$herdr_plan")" -eq 5 ]]

tmux_plan="$(env -u HERDR_ENV TMUX=/tmp/tmux "$WORKSPACE" "$HOME/project with spaces" --print)"
[[ "$(yq -r '.options.prefix' <<<"$tmux_plan")" == C-s ]]
[[ "$(yq -r '.session_name' <<<"$tmux_plan")" == project_with_spaces-agents ]]

set +e
env -u HERDR_ENV TMUX=/tmp/tmux "$WORKSPACE" "$HOME/project with spaces" \
  --backend herdr --print >"$HOME/outer.out" 2>"$HOME/outer.err"
status=$?
set -e
[[ "$status" -eq 2 ]]
grep -Fq 'Refusing to launch Herdr inside tmux' "$HOME/outer.err"

allowed="$(env -u HERDR_ENV TMUX=/tmp/tmux "$WORKSPACE" "$HOME/project with spaces" \
  --backend herdr --allow-nested --print)"
[[ "$(jq -r '.backend' <<<"$allowed")" == herdr ]]

printf '#!/bin/sh\nprintf "codex-launched\\n"\n' >"$HOME/bin/codex"
chmod +x "$HOME/bin/codex"
[[ "$($AGENT_LAUNCH codex)" == codex-launched ]]
set +e
"$AGENT_LAUNCH" unknown-agent >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]]

printf 'Agent workspace test passed\n'
