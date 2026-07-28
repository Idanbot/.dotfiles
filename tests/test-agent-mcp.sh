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

grep -Fq $'codex\tmcp add serena -- serena start-mcp-server --project-from-cwd --context=codex' "$CALLS"
grep -Fq $'claude\tmcp add --transport stdio --scope user context-mode -e CONTEXT_MODE_PLATFORM=claude-code -- context-mode' "$CALLS"

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
grep -Fq $'codex\tmcp remove serena' "$CALLS"
grep -Fq $'claude\tmcp remove context-mode --scope user' "$CALLS"
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

printf 'Agent MCP manager test passed\n'
