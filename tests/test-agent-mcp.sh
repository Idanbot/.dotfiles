#!/usr/bin/env bash
# Verify optional MCP toggles preserve unrelated per-agent configuration.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
MOCK_BIN="$TMP_ROOT/bin"
CALLS="$TMP_ROOT/calls"
mkdir -p "$MOCK_BIN" "$TMP_ROOT/home/.serena"
touch "$CALLS" "$TMP_ROOT/home/.serena/serena_config.yml"

make_mock() {
  local name="$1"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'printf "%%s\\t%%s\\n" %q "$*" >>%q\n' "$name" "$CALLS"
    printf 'exit 0\n'
  } >"$MOCK_BIN/$name"
  chmod +x "$MOCK_BIN/$name"
}

for command_name in codex claude serena context-mode; do
  make_mock "$command_name"
done
# Native mocks expose only their supported list interfaces and retain state.
export NATIVE_STATE="$TMP_ROOT/native"
mkdir -p "$NATIVE_STATE"
for command_name in codex claude; do
  cat >"$MOCK_BIN/$command_name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
agent="${0##*/}"
printf '%s\t%s\n' "$agent" "$*" >>"$NATIVE_STATE/calls"
case "$2" in
  add)
    for arg in "$@"; do
      case "$arg" in serena | context-mode) touch "$NATIVE_STATE/$agent-$arg"; break ;; esac
    done ;;
  remove)
    [[ "${FAIL_REMOVE:-}" != "$agent" ]] || exit 37
    [[ "${RETAIN_SERVER:-}" != "$agent" ]] || exit 0
    rm -f "$NATIVE_STATE/$agent-$3" ;;
  list)
    [[ "${FAIL_LIST:-}" != "$agent" ]] || exit 38
    if [[ "${MALFORMED_LIST:-}" == "$agent" ]]; then
      printf 'invalid configuration\n'
      exit 0
    fi
    if [[ "${EMPTY_LIST:-}" == "$agent" ]]; then
      if [[ "$agent" == codex ]]; then
        printf '[]\n'
      else
        printf 'No MCP servers configured. Use claude mcp add to add a server.\n'
      fi
      exit 0
    fi
    if [[ "$agent" == codex ]]; then
      [[ "$*" == 'mcp list --json' ]] || exit 2
      printf '['
      separator=''
      for server in keep serena context-mode; do
        if [[ "$server" == keep || -f "$NATIVE_STATE/$agent-$server" ]]; then
          printf '%s{"name":"%s"}' "$separator" "$server"
          separator=,
        fi
      done
      printf ']\n'
    else
      [[ "$*" == 'mcp list' ]] || exit 2
      printf 'keep: keep - Connected\n'
      for server in serena context-mode; do
        [[ ! -f "$NATIVE_STATE/$agent-$server" ]] || printf '%s: command - Connected\n' "$server"
      done
    fi ;;
esac
EOF
done
ln -s "$(command -v gojq)" "$MOCK_BIN/gojq"

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export PATH="$MOCK_BIN:/usr/bin:/bin"
SCRIPT="$DOTFILES_DIR/dot_local/bin/executable_agent-mcp"

mkdir -p \
  "$HOME/.gemini/config" \
  "$XDG_CONFIG_HOME/opencode" \
  "$HOME/.omp/agent"
printf '{"mcpServers":{"keep":{"command":"keep"}}}\n' \
  >"$HOME/.gemini/config/mcp_config.json"
printf '{"theme":"keep","mcp":{"keep":{"type":"local","command":["keep"]}}}\n' \
  >"$XDG_CONFIG_HOME/opencode/opencode.json"
printf '{"mcpServers":{"keep":{"command":"keep"}},"disabledServers":[]}\n' \
  >"$HOME/.omp/agent/mcp.json"

"$SCRIPT" enable all --agent codex,claude,agy,opencode,omp >/dev/null

grep -Fq $'codex\tmcp add serena -- serena start-mcp-server --project-from-cwd --context=codex' "$NATIVE_STATE/calls"
grep -Fq $'claude\tmcp add --transport stdio --scope user context-mode -e CONTEXT_MODE_PLATFORM=claude-code -- context-mode' "$NATIVE_STATE/calls"

AGY_CONFIG="$HOME/.gemini/config/mcp_config.json"
OPENCODE_CONFIG="$XDG_CONFIG_HOME/opencode/opencode.json"
OMP_CONFIG="$HOME/.omp/agent/mcp.json"

gojq -e \
  '.mcpServers.keep.command == "keep" and
   .mcpServers.serena.command == "serena" and
   .mcpServers["context-mode"].env.CONTEXT_MODE_PLATFORM == "antigravity-cli"' \
  "$AGY_CONFIG" >/dev/null
gojq -e \
  '.theme == "keep" and
   .mcp.keep.command[0] == "keep" and
   .mcp.serena.enabled == true and
   .mcp["context-mode"].enabled == true' \
  "$OPENCODE_CONFIG" >/dev/null
gojq -e \
  '.mcpServers.keep.command == "keep" and
   .mcpServers.serena.enabled == true and
   .mcpServers["context-mode"].env.CONTEXT_MODE_PLATFORM == "omp"' \
  "$OMP_CONFIG" >/dev/null

: >"$CALLS"
"$SCRIPT" disable all --agent codex,claude,agy,opencode,omp >/dev/null
grep -Fq $'codex\tmcp remove serena' "$NATIVE_STATE/calls"
grep -Fq $'claude\tmcp remove context-mode --scope user' "$NATIVE_STATE/calls"
gojq -e \
  '.mcpServers.keep.command == "keep" and
   .mcpServers.serena == null and
   .mcpServers["context-mode"] == null' \
  "$AGY_CONFIG" >/dev/null
gojq -e \
  '.mcp.keep.command[0] == "keep" and
   .mcp.serena.enabled == false and
   .mcp["context-mode"].enabled == false' \
  "$OPENCODE_CONFIG" >/dev/null
gojq -e \
  '.mcpServers.keep.command == "keep" and
   .mcpServers.serena.enabled == false and
   .mcpServers["context-mode"].enabled == false and
   (.disabledServers | index("serena")) != null and
   (.disabledServers | index("context-mode")) != null' \
  "$OMP_CONFIG" >/dev/null

status_output="$("$SCRIPT" status all --agent agy,opencode,omp)"
grep -Eq '^serena[[:space:]]+agy[[:space:]]+disabled$' <<<"$status_output"
status_output="$("$SCRIPT" status --agent agy)"
grep -Eq '^context-mode[[:space:]]+agy[[:space:]]+disabled$' <<<"$status_output"
if "$SCRIPT" enable >/dev/null 2>&1; then
  printf 'agent-mcp enable accepted a missing server selection\n' >&2
  exit 1
fi

for agent in codex claude; do
  touch "$NATIVE_STATE/$agent-serena"
  if FAIL_REMOVE="$agent" "$SCRIPT" disable serena --agent all >"$TMP_ROOT/result" 2>&1; then
    echo 'Removal failure reported success' >&2
    exit 1
  fi
  [[ -f "$NATIVE_STATE/$agent-serena" ]]
  ! grep -Eq "^disabled +serena +$agent$" "$TMP_ROOT/result" || exit 1
  if RETAIN_SERVER="$agent" "$SCRIPT" disable serena --agent "$agent" >"$TMP_ROOT/result" 2>&1; then
    echo 'Retained server reported success' >&2
    exit 1
  fi
  ! grep -Eq '^disabled ' "$TMP_ROOT/result" || exit 1
  rm "$NATIVE_STATE/$agent-serena"
  FAIL_REMOVE="$agent" "$SCRIPT" disable serena --agent "$agent" >/dev/null
  EMPTY_LIST="$agent" FAIL_REMOVE="$agent" "$SCRIPT" disable all --agent "$agent" >/dev/null
  if MALFORMED_LIST="$agent" "$SCRIPT" disable serena --agent "$agent" >/dev/null 2>&1; then
    echo 'Malformed native list reported success' >&2
    exit 1
  fi
  if FAIL_LIST="$agent" FAIL_REMOVE="$agent" "$SCRIPT" disable serena --agent "$agent" >/dev/null 2>&1; then
    echo 'Unverified absence reported success' >&2
    exit 1
  fi
done
if [[ "$(id -u)" != 0 ]]; then
  cp "$AGY_CONFIG" "$TMP_ROOT/readonly-before"
  chmod 400 "$AGY_CONFIG"
  if "$SCRIPT" disable serena --agent agy >"$TMP_ROOT/result" 2>&1; then
    echo 'Read-only configuration reported success' >&2
    exit 1
  fi
  cmp "$AGY_CONFIG" "$TMP_ROOT/readonly-before"
  chmod 600 "$AGY_CONFIG"
fi
printf 'broken json\n' >"$AGY_CONFIG"
cp "$AGY_CONFIG" "$TMP_ROOT/broken-before"
if "$SCRIPT" disable all --agent all >"$TMP_ROOT/result" 2>&1; then
  echo 'Malformed configuration reported success' >&2
  exit 1
fi
cmp "$AGY_CONFIG" "$TMP_ROOT/broken-before"
grep -Eq '^disabled +context-mode +omp$' "$TMP_ROOT/result"

printf 'Agent MCP manager test passed\n'
