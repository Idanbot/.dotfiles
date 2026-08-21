#!/usr/bin/env bash
# Verify agent readiness reporting is read-only and registry-driven.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
MOCK_BIN="$TMP_ROOT/bin"
HOME_DIR="$TMP_ROOT/home"
REGISTRY="$TMP_ROOT/agents.yaml"
mkdir -p "$MOCK_BIN" "$HOME_DIR"

cat >"$REGISTRY" <<'EOF'
workspace:
  agents:
    - codex
    - optional
agents:
  codex:
    command: codex
    required: true
  optional:
    command: missing-agent-fixture
    required: false
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$MOCK_BIN/codex"
chmod +x "$MOCK_BIN/codex"

SCRIPT="$DOTFILES_DIR/dot_local/bin/executable_dot-agent-status"
status_output="$(
  HOME="$HOME_DIR" PATH="$MOCK_BIN:/usr/bin:/bin" \
    "$SCRIPT" --registry "$REGISTRY"
)"
grep -Fq '[PASS] codex' <<<"$status_output"
grep -Fq '[INFO] optional' <<<"$status_output"
grep -Fq 'Agent readiness: 1/2 available' <<<"$status_output"

compact_output="$(
  HOME="$HOME_DIR" PATH="$MOCK_BIN:/usr/bin:/bin" \
    "$SCRIPT" --registry "$REGISTRY" --compact
)"
[[ "$compact_output" == 'agents 1/2' ]]

HOME="$HOME_DIR" PATH="$MOCK_BIN:/usr/bin:/bin" \
  "$SCRIPT" --registry "$REGISTRY" --agents codex --check >/dev/null
REQUIRED_REGISTRY="$TMP_ROOT/required-agents.yaml"
sed 's/required: false/required: true/' "$REGISTRY" >"$REQUIRED_REGISTRY"
if HOME="$HOME_DIR" PATH="$MOCK_BIN:/usr/bin:/bin" \
  "$SCRIPT" --registry "$REQUIRED_REGISTRY" --check >/dev/null 2>&1; then
  printf 'Required missing agent was reported as healthy\n' >&2
  exit 1
fi

[[ ! -e "$HOME_DIR/.config/dotfiles" ]]
printf 'Agent status test passed\n'
