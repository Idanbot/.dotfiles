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

grep -Fq 'herdr pane run' "$WORKSPACE"
! grep -Fq 'herdr agent start "$agent" --workspace' "$WORKSPACE"

rendered="$(env -u HERDR_ENV -u TMUX "$WORKSPACE" "$HOME/project with spaces" \
  --backend tmux --name test-agents --print)"
grep -Fq 'session_name: "test-agents"' <<<"$rendered"
grep -Fq "start_directory: \"$HOME/project with spaces\"" <<<"$rendered"
[[ "$(yq -r '.options.prefix' <<<"$rendered")" == C-s ]]
for agent in codex antigravity claude opencode omp; do
  grep -Fq "dot-agent-launch --registry $DOTFILES_AGENT_REGISTRY $agent" <<<"$rendered"
done
printf '%s\n' "$rendered" | yq . >/dev/null

subset="$(env -u HERDR_ENV -u TMUX "$WORKSPACE" "$HOME/project with spaces" \
  --backend tmux --agents codex,claude --restart-agents --print)"
grep -Fq 'dot-agent-launch --restart --registry' <<<"$subset"
[[ "$(printf '%s\n' "$subset" | yq -r '.windows | length')" -eq 3 ]]

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
[[ "$(yq -r '.session_name' <<<"$tmux_plan")" == project_with_spaces-agents-* ]]

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
[[ "$(jq -r '.restart_agents' <<<"$allowed")" == false ]]

printf '#!/bin/sh\nprintf "codex-launched\\n"\n' >"$HOME/bin/codex"
chmod +x "$HOME/bin/codex"
health="$(env -u HERDR_ENV -u TMUX "$WORKSPACE" "$HOME/project with spaces" \
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
for backend in tmux herdr; do
  plan_name() {
    env -u HERDR_ENV -u TMUX "$WORKSPACE" "$1" --backend "$backend" --print |
      yq -r '.session_name // .workspace'
  }
  [[ "$(plan_name "$HOME/one/api")" != "$(plan_name "$HOME/two/api")" ]]
  [[ "$(plan_name "$HOME/a.b")" != "$(plan_name "$HOME/a b")" ]]
  [[ "$(plan_name "$HOME/one/api")" == "$(plan_name "$HOME/api-link")" ]]
done
cat >"$HOME/bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'workspace list') jq -n --arg cwd "$EXISTING_CWD" '{result:{workspaces:[{workspace_id:"w1",label:"shared",cwd:$cwd}]}}' ;;
  'workspace focus w1') touch "$HOME/focused" ;;
  *) exit 90 ;;
esac
EOF
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
chmod +x "$HOME/bin/herdr" "$HOME/bin/tmux"
export EXISTING_CWD="$HOME/one/api"
for backend in tmux herdr; do
  nesting=TMUX
  [[ "$backend" != herdr ]] || nesting=HERDR_ENV
  env -u TMUX -u HERDR_ENV "$nesting=1" "$WORKSPACE" "$HOME/api-link" \
    --backend "$backend" --name shared >/dev/null
  [[ -f "$HOME/focused" ]]
  rm "$HOME/focused"
  if env -u TMUX -u HERDR_ENV "$nesting=1" "$WORKSPACE" "$HOME/two/api" \
    --backend "$backend" --name shared >"$HOME/collision" 2>&1; then
    echo 'Workspace collision accepted' >&2
    exit 1
  fi
  [[ ! -e "$HOME/focused" ]]
  grep -Fq "$HOME/one/api" "$HOME/collision"
  grep -Fq "$HOME/two/api" "$HOME/collision"
done

export WORKSPACE_STATE="$HOME/workspace-state"
mkdir -p "$WORKSPACE_STATE"
cat >"$HOME/bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  'workspace list')
    for file in "$WORKSPACE_STATE"/*.cwd; do
      [[ -f "$file" ]] || continue
      name="${file##*/}"; name="${name%.cwd}"
      jq -n --arg cwd "$(<"$file")" --arg name "$name" \
        '{workspace_id:$name,label:$name,cwd:$cwd}'
    done | jq -s '{result:{workspaces:.}}' ;;
  'workspace create')
    [[ "$3" == --cwd && "$5" == --label ]] || exit 90
    printf '%s\n' "$4" >"$WORKSPACE_STATE/$6.cwd"
    printf 'create\n' >>"$WORKSPACE_STATE/creates"
    jq -n --arg id "$6" '{result:{workspace:{workspace_id:$id},tab:{tab_id:"root"}}}' ;;
  'tab create') printf '{"result":{"root_pane":{"pane_id":"pane"}}}\n' ;;
  'workspace focus' | 'tab rename' | 'tab focus' | 'pane run') exit 0 ;;
  *) exit 90 ;;
esac
EOF
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
chmod +x "$HOME/bin/herdr" "$HOME/bin/tmux" "$HOME/bin/uvx"
for backend in tmux herdr; do
  rm -f "$WORKSPACE_STATE"/*
  nesting=TMUX
  [[ "$backend" != herdr ]] || nesting=HERDR_ENV
  for directory in "$HOME/one/api" "$HOME/two/api" "$HOME/a.b" "$HOME/a b" \
    "$HOME/api-link" "$HOME/one/api"; do
    env -u TMUX -u HERDR_ENV "$nesting=1" "$WORKSPACE" "$directory" \
      --backend "$backend" --agents codex >/dev/null
  done
  [[ "$(wc -l <"$WORKSPACE_STATE/creates")" -eq 4 ]]
done

printf 'Agent workspace test passed\n'
