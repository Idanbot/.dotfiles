#!/usr/bin/env bash
# Exercise both agent workspace backends and optional MCP state in Docker.

set -Eeuo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
ARTIFACT_DIR="${DOTFILES_E2E_ARTIFACT_DIR:-/artifacts/agent-workspace}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-agent-workspace.XXXXXX")"
HOME="$TMP_ROOT/home"
XDG_CONFIG_HOME="$HOME/.config"
DOTFILES_STATE_DIR="$TMP_ROOT/state"
DOTFILES_AGENT_REGISTRY="$XDG_CONFIG_HOME/dotfiles/agents.yaml"
MOCK_AGENT_STATE="$TMP_ROOT/mock-agents"
AGENT_RUN_LOG="$ARTIFACT_DIR/agent-launches.tsv"
WORKSPACE_BACKEND_LOG="$ARTIFACT_DIR/tmuxp-backend.tsv"
HERDR_BACKEND_LOG="$ARTIFACT_DIR/herdr-backend.tsv"
HERDR_BACKEND_STATE="$TMP_ROOT/herdr"
TMUX_BACKEND_LOG="$ARTIFACT_DIR/tmux.tsv"
LOG_FILE="$ARTIFACT_DIR/workspace.log"
EVENT_LOG="$ARTIFACT_DIR/workspace-events.jsonl"
SUMMARY_JSON="$ARTIFACT_DIR/summary.json"
SUMMARY_MD="$ARTIFACT_DIR/summary.md"
PASSED=0
FAILED=0
TOTAL=0
STARTED_NANOS="$(date +%s%N)"
FINALIZED=false

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p \
  "$ARTIFACT_DIR" \
  "$HOME/bin" \
  "$XDG_CONFIG_HOME/dotfiles" \
  "$XDG_CONFIG_HOME/tmuxp" \
  "$XDG_CONFIG_HOME/opencode" \
  "$HOME/.gemini/config" \
  "$HOME/.omp/agent" \
  "$DOTFILES_STATE_DIR" \
  "$MOCK_AGENT_STATE" \
  "$HERDR_BACKEND_STATE"
chmod 700 "$HOME" "$DOTFILES_STATE_DIR" "$MOCK_AGENT_STATE" "$HERDR_BACKEND_STATE"
: >"$AGENT_RUN_LOG"
: >"$WORKSPACE_BACKEND_LOG"
: >"$HERDR_BACKEND_LOG"
: >"$LOG_FILE"
: >"$EVENT_LOG"
exec > >(tee -a "$LOG_FILE") 2>&1

# shellcheck source=/dev/null
source "$DOTFILES_DIR/scripts/performance-format.sh"

export HOME XDG_CONFIG_HOME DOTFILES_STATE_DIR DOTFILES_AGENT_REGISTRY
export MOCK_AGENT_STATE AGENT_RUN_LOG WORKSPACE_BACKEND_LOG HERDR_BACKEND_LOG
export HERDR_BACKEND_STATE TMUX_BACKEND_LOG
export PATH="$HOME/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

event() {
  local name="$1" state="$2" elapsed_ms="${3:-0}"
  jq -cn \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg name "$name" \
    --arg state "$state" \
    --argjson elapsed_ms "$elapsed_ms" \
    '{timestamp: $timestamp, case: $name, state: $state, elapsed_ms: $elapsed_ms}' \
    >>"$EVENT_LOG"
}

finalize() {
  local status="$1" ended_nanos elapsed_ms result
  [[ "$FINALIZED" == true ]] && return 0
  FINALIZED=true
  ended_nanos="$(date +%s%N)"
  elapsed_ms="$(((ended_nanos - STARTED_NANOS) / 1000000))"
  ((elapsed_ms < 0)) && elapsed_ms=0
  result=fail
  [[ "$status" -eq 0 ]] && result=pass
  jq -n \
    --arg result "$result" \
    --argjson exit_code "$status" \
    --argjson total "$TOTAL" \
    --argjson passed "$PASSED" \
    --argjson failed "$FAILED" \
    --argjson duration_ms "$elapsed_ms" \
    --argjson duration_seconds "$(duration_ms_to_seconds "$elapsed_ms")" \
    --arg duration_human "$(format_duration_ms "$elapsed_ms")" \
    '{result: $result, exit_code: $exit_code, cases: {total: $total, passed: $passed, failed: $failed}, duration_ms: $duration_ms, duration_seconds: $duration_seconds, duration_human: $duration_human}' \
    >"$SUMMARY_JSON" || true
  {
    printf '# Agent Workspace Docker E2E\n\n'
    printf -- '- Result: `%s`\n' "$result"
    printf -- '- Cases: `%s/%s` passed\n' "$PASSED" "$TOTAL"
    printf -- '- Duration: `%s`\n' "$(format_duration_ms "$elapsed_ms")"
    printf -- '- Backends: tmuxp command contract and Herdr API fixture\n'
    printf -- '- Agent launch trace: `%s`\n' "$(basename "$AGENT_RUN_LOG")"
  } >"$SUMMARY_MD" || true
  chmod -R u=rwX,go=rX "$ARTIFACT_DIR" 2>/dev/null || true
}
trap 'status=$?; trap - EXIT; finalize "$status"; cleanup; exit "$status"' EXIT

run_case() {
  local name="$1" started_nanos ended_nanos elapsed_ms status
  shift
  TOTAL=$((TOTAL + 1))
  started_nanos="$(date +%s%N)"
  event "$name" start 0
  set +e
  # Do not invoke this subshell from an if/!/|| context: Bash disables errexit
  # throughout functions in those contexts, even after an explicit set -e.
  (
    set -Eeuo pipefail
    trap 'status=$?; if [[ $- == *e* ]]; then printf "[ERROR] case=%s line=%s command=%s exit=%s\n" "$name" "$LINENO" "$BASH_COMMAND" "$status" >&2; fi' ERR
    "$@"
  )
  status=$?
  set -e
  ended_nanos="$(date +%s%N)"
  elapsed_ms="$(((ended_nanos - started_nanos) / 1000000))"
  ((elapsed_ms < 0)) && elapsed_ms=0
  if [[ "$status" -eq 0 ]]; then
    PASSED=$((PASSED + 1))
    printf '[PASS] %s (%s)\n' "$name" "$(format_duration_ms "$elapsed_ms")"
    event "$name" pass "$elapsed_ms"
  else
    FAILED=$((FAILED + 1))
    printf '[FAIL] %s (%s, exit %s)\n' "$name" "$(format_duration_ms "$elapsed_ms")" "$status"
    event "$name" fail "$elapsed_ms"
  fi
  # Cases share filesystem fixtures, but their shell state is isolated. Collect
  # every result and let the suite exit nonzero after recording all cases.
  return 0
}

write_executable() {
  local path="$1"
  shift
  printf '%s\n' "$@" >"$path"
  chmod 755 "$path"
}

write_executable "$HOME/bin/mock-agent" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'agent="${0##*/}"' \
  'state_root="${MOCK_AGENT_STATE:?}"' \
  'mkdir -p "$state_root/$agent"' \
  'if [[ "${1:-}" == mcp ]]; then' \
  '  action="${2:-}"' \
  '  if [[ "$action" == list ]]; then' \
  '    names=()' \
  '    for candidate in serena context-mode; do' \
  '      [[ ! -e "$state_root/$agent/$candidate" ]] || names+=("$candidate")' \
  '    done' \
  '    if [[ "$agent" == codex ]]; then' \
  '      printf "%s\n" "${names[@]}" | jq -Rn "[inputs | select(length > 0) | {name: .}]"' \
  '    elif ((${#names[@]})); then' \
  '      printf "%s: fixture\n" "${names[@]}"' \
  '    else' \
  '      printf "No MCP servers configured.\n"' \
  '    fi' \
  '    exit 0' \
  '  fi' \
  '  server=""' \
  '  case "$action" in' \
  '    remove | get) server="${3:-}" ;;' \
  '    add)' \
  '      for arg in "$@"; do' \
  '        [[ "$arg" == serena || "$arg" == context-mode ]] && server="$arg"' \
  '      done' \
  '      ;;' \
  '  esac' \
  '  [[ -n "$server" ]] || exit 2' \
  '  case "$action" in' \
  '    add) : >"$state_root/$agent/$server" ;;' \
  '    remove) rm -f "$state_root/$agent/$server" ;;' \
  '    get) [[ -e "$state_root/$agent/$server" ]] ;;' \
  '    *) exit 2 ;;' \
  '  esac' \
  '  exit 0' \
  'fi' \
  'if [[ "${1:-}" == --version ]]; then' \
  '  printf "%s fixture\\n" "$agent"' \
  '  exit 0' \
  'fi' \
  'printf "%s\\t%s\\t%s\\n" "$agent" "$PWD" "$*" >>"${AGENT_RUN_LOG:?}"' \
  'if [[ -f "$state_root/$agent/exit-status" ]]; then' \
  '  exit "$(<"$state_root/$agent/exit-status")"' \
  'fi' \
  'printf "agent=%s cwd=%s\\n" "$agent" "$PWD"'

for agent in codex agy claude opencode omp; do
  ln -s mock-agent "$HOME/bin/$agent"
done
write_executable "$HOME/bin/serena" '#!/usr/bin/env bash' 'exit 0'
write_executable "$HOME/bin/context-mode" '#!/usr/bin/env bash' 'exit 0'
write_executable "$HOME/bin/tmux" '#!/usr/bin/env bash' 'printf "%s\\n" "$*" >>"${TMUX_BACKEND_LOG:?}"'
ln -s "$DOTFILES_DIR/dot_local/bin/executable_dot-agent-launch" \
  "$HOME/bin/dot-agent-launch"
ln -s "$DOTFILES_DIR/dot_local/bin/executable_dot-agent-status" \
  "$HOME/bin/dot-agent-status"
ln -s "$DOTFILES_DIR/dot_local/bin/executable_dot-workspace" \
  "$HOME/bin/dot-workspace"
ln -s "$DOTFILES_DIR/dot_local/bin/executable_agent-mcp" \
  "$HOME/bin/agent-mcp"
cp "$DOTFILES_DIR/agents.yaml" "$DOTFILES_AGENT_REGISTRY"
cp "$DOTFILES_DIR/dot_config/tmuxp/agent-workspace.yaml" \
  "$XDG_CONFIG_HOME/tmuxp/agent-workspace.yaml"

printf '{"mcpServers":{"keep":{"command":"keep"}}}\n' \
  >"$HOME/.gemini/config/mcp_config.json"
printf '{"theme":"keep","mcp":{"keep":{"type":"local","command":["keep"]}}}\n' \
  >"$XDG_CONFIG_HOME/opencode/opencode.json"
printf '{"mcpServers":{"keep":{"command":"keep"}},"disabledServers":[]}\n' \
  >"$HOME/.omp/agent/mcp.json"

WORKSPACE_DIR="$TMP_ROOT/project with spaces"
mkdir -p "$WORKSPACE_DIR"
export WORKSPACE_DIR

test_agent_preflight() {
  local output
  write_executable "$HOME/bin/uvx" '#!/usr/bin/env bash' 'exit 0'
  output="$(dot-agent-status --check)"
  grep -Fq '[PASS] codex' <<<"$output"
  grep -Fq '[PASS] antigravity' <<<"$output"
  grep -Fq '[PASS] claude' <<<"$output"
  grep -Fq '[PASS] opencode' <<<"$output"
  grep -Fq '[PASS] omp' <<<"$output"
  dot-workspace "$WORKSPACE_DIR" --backend tmux --check >/dev/null
}

test_mcp_toggles() {
  local status_output enabled_count
  status_output="$(agent-mcp status all)"
  if grep -Eq '[[:space:]]enabled$' <<<"$status_output"; then return 1; fi
  agent-mcp enable all --agent codex,claude,agy,opencode,omp >/dev/null
  status_output="$(agent-mcp status all)"
  enabled_count="$(grep -Ec '[[:space:]]enabled$' <<<"$status_output" || true)"
  [[ "$enabled_count" -eq 10 ]]
  gojq -e '.mcpServers.keep.command == "keep"' \
    "$HOME/.gemini/config/mcp_config.json" >/dev/null
  gojq -e '.theme == "keep" and .mcp.keep.command[0] == "keep"' \
    "$XDG_CONFIG_HOME/opencode/opencode.json" >/dev/null
  gojq -e '.mcpServers.keep.command == "keep"' \
    "$HOME/.omp/agent/mcp.json" >/dev/null
  agent-mcp disable all --agent codex,claude,agy,opencode,omp >/dev/null
  status_output="$(agent-mcp status all)"
  if grep -Eq '[[:space:]]enabled$' <<<"$status_output"; then return 1; fi
}

test_tmuxp_backend() {
  cat >"$HOME/bin/uvx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\t%s\n' "$PWD" "$*" >>"${WORKSPACE_BACKEND_LOG:?}"
[[ "${1:-}" == --from && "${2:-}" == tmuxp==1.74.0 && "${3:-}" == tmuxp && "${4:-}" == load && "${5:-}" == -y ]]
yaml="${!#}"
start_directory="$(yq -r '.start_directory' "$yaml")"
[[ "$start_directory" == "$WORKSPACE_DIR" ]]
[[ "$(yq -r '.windows | length' "$yaml")" -eq 6 ]]
while IFS= read -r command; do
  [[ -n "$command" ]] || continue
  (cd "$start_directory" && bash -c "$command")
done < <(yq -r '.windows[].panes[] | select(.shell_command != null) | .shell_command' "$yaml")
EOF
  chmod 755 "$HOME/bin/uvx"
  dot-workspace "$WORKSPACE_DIR" --backend tmux --name docker-tmux
  [[ "$(wc -l <"$AGENT_RUN_LOG")" -eq 5 ]]
  grep -Fq 'tmuxp==1.74.0 tmuxp load -y' "$WORKSPACE_BACKEND_LOG"
}

test_herdr_backend() {
  cat >"$HOME/bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log="${HERDR_BACKEND_LOG:?}"
state="${HERDR_BACKEND_STATE:?}"
printf '%s\t%s\n' "$PWD" "$*" >>"$log"
case "${1:-}:${2:-}" in
  workspace:list)
    if [[ -e "$state/created" ]]; then
      cwd="$(<"$state/workdir")"
      encoded_cwd="$(jq -Rn --arg value "$cwd" '$value')"
      printf '{"result":{"workspaces":[{"workspace_id":"workspace-1","label":"docker-herdr","cwd":%s}]}}\n' "$encoded_cwd"
    else
      printf '%s\n' '{"result":{"workspaces":[]}}'
    fi
    ;;
  workspace:create)
    cwd=""
    label=""
    while (($#)); do
      case "$1" in
        --cwd) cwd="${2:-}"; shift 2 ;;
        --label) label="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$cwd" >"$state/workdir"
    touch "$state/created"
    printf '{"result":{"workspace":{"workspace_id":"workspace-1","label":"%s"},"tab":{"tab_id":"tab-root"}}}\n' "$label"
    ;;
  tab:create)
    cwd=""
    label=""
    while (($#)); do
      case "$1" in
        --cwd) cwd="${2:-}"; shift 2 ;;
        --label) label="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$cwd" >"$state/pane-$label.cwd"
    printf '{"result":{"root_pane":{"pane_id":"pane-%s"}}}\n' "$label"
    ;;
  pane:run)
    pane_id="${3:-}"
    launch_command="${4:-}"
    cwd="$(<"$state/$pane_id.cwd")"
    (cd "$cwd" && bash -c "$launch_command")
    ;;
  workspace:focus | tab:focus | tab:rename)
    ;;
  *)
    printf 'unexpected Herdr command: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
  chmod 755 "$HOME/bin/herdr"
  HERDR_ENV=1 dot-workspace "$WORKSPACE_DIR" \
    --backend herdr --name docker-herdr
  [[ "$(wc -l <"$AGENT_RUN_LOG")" -eq 10 ]]
  grep -Fq "workspace create --cwd $WORKSPACE_DIR --label docker-herdr --focus" \
    "$HERDR_BACKEND_LOG"
  for agent in codex antigravity claude opencode omp; do
    grep -Fq "tab create --workspace workspace-1 --cwd $WORKSPACE_DIR --label $agent --no-focus" \
      "$HERDR_BACKEND_LOG"
  done
  HERDR_ENV=1 dot-workspace "$WORKSPACE_DIR" \
    --backend herdr --name docker-herdr
  [[ "$(wc -l <"$AGENT_RUN_LOG")" -eq 10 ]]
  grep -Fq 'workspace focus workspace-1' "$HERDR_BACKEND_LOG"
}

test_directory_propagation() {
  local agent count
  [[ "$(wc -l <"$AGENT_RUN_LOG")" -eq 10 ]]
  for agent in codex agy claude opencode omp; do
    count="$(awk -F '\t' -v agent="$agent" -v directory="$WORKSPACE_DIR" \
      '$1 == agent && $2 == directory {count += 1} END {print count + 0}' \
      "$AGENT_RUN_LOG")"
    [[ "$count" -eq 2 ]]
  done
}

test_mocked_failures() {
  local output status
  rm -f "$HOME/bin/omp"
  set +e
  output="$(dot-agent-status --agents omp --check 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]]
  printf '%s\n' "$output"
  grep -Fq '[WARN] omp' <<<"$output"
  set +e
  output="$(dot-agent-launch --registry "$DOTFILES_AGENT_REGISTRY" --check omp 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]]
  printf '%s\n' "$output"
  grep -Fq 'omp -> omp is not installed' <<<"$output"

  printf '42\n' >"$MOCK_AGENT_STATE/codex/exit-status"
  : >"$AGENT_RUN_LOG"
  set +e
  output="$(DOTFILES_AGENT_MAX_RESTARTS=1 DOTFILES_AGENT_RESTART_DELAY=0 \
    dot-agent-launch --restart --registry "$DOTFILES_AGENT_REGISTRY" codex \
    2>&1)"
  status=$?
  set -e
  printf '%s\n' "$output"
  [[ "$status" -eq 42 ]]
  [[ "$(wc -l <"$AGENT_RUN_LOG")" -eq 2 ]]
}

printf '== Agent Workspace Docker E2E ==\n'
printf 'workspace=%s\nartifacts=%s\n' "$WORKSPACE_DIR" "$ARTIFACT_DIR"
run_case 'agent CLI preflight' test_agent_preflight
run_case 'MCP enable and disable' test_mcp_toggles
run_case 'tmuxp backend execution' test_tmuxp_backend
run_case 'Herdr backend execution and reuse' test_herdr_backend
run_case 'working-directory propagation' test_directory_propagation
run_case 'missing and crashing agent handling' test_mocked_failures
printf '\nAgent workspace E2E: %s/%s passed, %s failed\n' "$PASSED" "$TOTAL" "$FAILED"
[[ "$FAILED" -eq 0 ]]
