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
ln -s "$DOTFILES_DIR/dot_local/bin/executable_dot-agent-launch" \
  "$HOME/bin/dot-agent-launch"
chmod +x "$HOME/bin/uvx" "$HOME/bin/tmux"

WORKSPACE="$DOTFILES_DIR/dot_local/bin/executable_dot-workspace"
AGENT_LAUNCH="$DOTFILES_DIR/dot_local/bin/executable_dot-agent-launch"

preview="$(env -u TMUX "$WORKSPACE" "$HOME/project with spaces" --backend tmux --preset review --plan)"
jq -e '.agents == ["codex", "claude"] and .mutates == false and .preset == "review"' <<<"$preview" >/dev/null
preview="$(env -u TMUX "$WORKSPACE" "$HOME/project with spaces" --backend tmux --preset implementation --plan)"
jq -e '.agents == ["codex", "antigravity", "opencode", "omp"] and .mutates == false' <<<"$preview" >/dev/null
(
  mkdir -p "$HOME/preview-bin"
  cat >"$HOME/preview-bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'terminal\ncodex\nextra\n' ;;
  display-message) printf '%s\n' "$PREVIEW_WORKDIR" ;;
  *) touch "$HOME/unexpected-mutation"; exit 99 ;;
esac
EOF
  chmod +x "$HOME/preview-bin/"*
  export PATH="$HOME/preview-bin:$PATH" PREVIEW_WORKDIR="$HOME/project with spaces"
  for _ in 1 2; do
    preview="$(env -u TMUX "$WORKSPACE" "$PREVIEW_WORKDIR" --backend tmux --name preview --preset review --plan)"
    jq -e '.add == ["claude"] and .extra_preserved == ["extra"] and .mutates == false' <<<"$preview" >/dev/null
    [[ ! -e "$HOME/unexpected-mutation" ]]
  done
)
if "$WORKSPACE" --preset missing --plan >/dev/null 2>&1; then
  printf 'Unknown preset accepted\n' >&2
  exit 1
fi
if "$WORKSPACE" --preset review --agents codex --plan >/dev/null 2>&1; then
  printf 'Conflicting preset/agent selection accepted\n' >&2
  exit 1
fi

rendered="$(env -u TMUX "$WORKSPACE" "$HOME/project with spaces" \
  --backend tmux --name test-agents --print)"
grep -Fq 'session_name: "test-agents"' <<<"$rendered"
grep -Fq "start_directory: \"$HOME/project with spaces\"" <<<"$rendered"
[[ "$(yq -r '.options.prefix' <<<"$rendered")" == C-s ]]
for agent in codex antigravity claude opencode omp; do
  grep -Fq "dot-agent-launch --registry $DOTFILES_AGENT_REGISTRY $agent" <<<"$rendered"
done
printf '%s\n' "$rendered" | yq . >/dev/null

subset="$(env -u TMUX "$WORKSPACE" "$HOME/project with spaces" \
  --backend tmux --agents codex,claude --restart-agents --print)"
grep -Fq 'dot-agent-launch --restart --registry' <<<"$subset"
[[ "$(printf '%s\n' "$subset" | yq -r '.windows | length')" -eq 3 ]]

printf '#!/bin/sh\nprintf "codex-launched\\n"\n' >"$HOME/bin/codex"
chmod +x "$HOME/bin/codex"
health="$(env -u TMUX "$WORKSPACE" "$HOME/project with spaces" \
  --backend tmux --agents codex --check)"
grep -Fq '[PASS] codex' <<<"$health"
"$AGENT_LAUNCH" --registry "$DOTFILES_AGENT_REGISTRY" --check codex >/dev/null
[[ "$($AGENT_LAUNCH codex)" == codex-launched ]]
mkdir -p "$HOME/pane-home"
[[ "$(HOME="$HOME/pane-home" "$AGENT_LAUNCH" --registry "$DOTFILES_AGENT_REGISTRY" \
  codex)" == codex-launched ]]
set +e
"$AGENT_LAUNCH" unknown-agent >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]]

printf '#!/bin/sh\nprintf "%%s\\n" restart >>"%s"\nexit 1\n' "$HOME/restarts" >"$HOME/bin/codex"
chmod +x "$HOME/bin/codex"
: >"$HOME/restarts"
set +e
DOTFILES_AGENT_MAX_RESTARTS=1 DOTFILES_AGENT_RESTART_DELAY=0 \
  "$AGENT_LAUNCH" --restart --registry "$DOTFILES_AGENT_REGISTRY" codex >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]]
[[ "$(wc -l <"$HOME/restarts")" -eq 2 ]]

mkdir -p "$HOME/one/api" "$HOME/two/api" "$HOME/a.b" "$HOME/a b"
ln -s "$HOME/one/api" "$HOME/api-link"
plan_name() {
  env -u TMUX "$WORKSPACE" "$1" --backend tmux --print |
    yq -r '.session_name // .workspace'
}
[[ "$(plan_name "$HOME/one/api")" != "$(plan_name "$HOME/two/api")" ]]
[[ "$(plan_name "$HOME/a.b")" != "$(plan_name "$HOME/a b")" ]]
[[ "$(plan_name "$HOME/one/api")" == "$(plan_name "$HOME/api-link")" ]]
cat >"$HOME/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  has-session) exit 0 ;;
  list-sessions) printf 'shared\n' ;;
  display-message) printf '%s\n' "$EXISTING_CWD" ;;
  attach-session | switch-client) touch "$HOME/focused" ;;
  *) exit 90 ;;
esac
EOF
chmod +x "$HOME/bin/tmux"
export EXISTING_CWD="$HOME/one/api"
nesting=TMUX
env -u TMUX "$nesting=1" "$WORKSPACE" "$HOME/api-link" \
  --backend tmux --name shared >/dev/null
[[ -f "$HOME/focused" ]]
rm "$HOME/focused"
if env -u TMUX "$nesting=1" "$WORKSPACE" "$HOME/two/api" \
  --backend tmux --name shared >"$HOME/collision" 2>&1; then
  echo 'Workspace collision accepted' >&2
  exit 1
fi
[[ ! -e "$HOME/focused" ]]
grep -Fq "$HOME/one/api" "$HOME/collision"
grep -Fq "$HOME/two/api" "$HOME/collision"

export WORKSPACE_STATE="$HOME/workspace-state"
mkdir -p "$WORKSPACE_STATE"
cat >"$HOME/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  has-session) compgen -G "$WORKSPACE_STATE/*.cwd" >/dev/null ;;
  list-sessions)
    for file in "$WORKSPACE_STATE"/*.cwd; do
      name="${file##*/}"; printf '%s\n' "${name%.cwd}"
    done ;;
  display-message) cat "$WORKSPACE_STATE/${4#=}.cwd" ;;
  attach-session | switch-client) exit 0 ;;
  *) exit 90 ;;
esac
EOF
cat >"$HOME/bin/uvx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
plan="${!#}"
name="$(yq -r '.session_name' "$plan")"
yq -r '.start_directory' "$plan" >"$WORKSPACE_STATE/$name.cwd"
printf 'create\n' >>"$WORKSPACE_STATE/creates"
EOF
chmod +x "$HOME/bin/tmux" "$HOME/bin/uvx"
rm -f "$WORKSPACE_STATE"/*
nesting=TMUX
for directory in "$HOME/one/api" "$HOME/two/api" "$HOME/a.b" "$HOME/a b" \
  "$HOME/api-link" "$HOME/one/api"; do
  env -u TMUX "$nesting=1" "$WORKSPACE" "$directory" \
    --backend tmux --agents codex >/dev/null
done
[[ "$(wc -l <"$WORKSPACE_STATE/creates")" -eq 4 ]]

printf 'Agent workspace test passed\n'
