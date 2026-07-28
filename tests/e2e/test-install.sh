#!/usr/bin/env bash
# Execute the same installer path used by the public one-liner and retain rich diagnostics.

set -Eeuo pipefail

PROFILE="${E2E_PROFILE:-base}"
PASSES="${E2E_PASSES:-2}"
ARTIFACT_DIR="/artifacts/${PROFILE}-${DOTFILES_WSL:-false}"
STATE_DIR="$HOME/.local/state/dotfiles"
mkdir -p "$ARTIFACT_DIR"
mkdir -p "$HOME/.config/dotfiles"
printf 'history-sentinel\n' >"$HOME/.zsh_history"
printf '# e2e-local-sentinel\n' >"$HOME/.config/dotfiles/local.zsh"
chmod 600 "$HOME/.zsh_history" "$HOME/.config/dotfiles/local.zsh"

collect_observability() {
  mkdir -p "$ARTIFACT_DIR/state"
  [[ ! -d "$STATE_DIR/logs" ]] || cp -a "$STATE_DIR/logs" "$ARTIFACT_DIR/state/"
  [[ ! -d "$STATE_DIR/runs" ]] || cp -a "$STATE_DIR/runs" "$ARTIFACT_DIR/state/"
  [[ ! -f "$STATE_DIR/installed.tsv" ]] || cp "$STATE_DIR/installed.tsv" "$ARTIFACT_DIR/state/"
}

collect_diagnostics() {
  local status="$1"
  {
    printf 'exit=%s\nprofile=%s\nwsl=%s\n' "$status" "$PROFILE" "${DOTFILES_WSL:-auto}"
    printf '\nDisk:\n'
    df -h
    printf '\nMemory:\n'
    free -h || true
    printf '\nProcesses:\n'
    ps aux || true
    printf '\nAPT sources:\n'
    find /etc/apt -maxdepth 2 -type f -print -exec sed -n '1,80p' {} \; 2>/dev/null || true
    printf '\nHome files:\n'
    find "$HOME" -maxdepth 4 -printf '%M %u:%g %p\n' 2>/dev/null | sort || true
    printf '\nRun summaries:\n'
    find "$STATE_DIR/runs" -name summary.json -exec sh -c 'echo ===$1===; cat "$1"' _ {} \; 2>/dev/null || true
  } >"$ARTIFACT_DIR/diagnostics.txt"
  collect_observability
  # CI artifacts contain only synthetic test-home data and must be readable by
  # the host runner even when the container and runner use different UIDs.
  chmod -R u=rwX,go=rX "$ARTIFACT_DIR"
}
trap 'status=$?; collect_diagnostics "$status"; exit "$status"' EXIT

printf 'profile=%s\nwsl=%s\npasses=%s\n' "$PROFILE" "${DOTFILES_WSL:-auto}" "$PASSES" >"$ARTIFACT_DIR/context.txt"
env | sed -E 's/((TOKEN|PASSWORD|SECRET|KEY)=).*/\1[REDACTED]/I' | sort >"$ARTIFACT_DIR/environment.txt"

for pass in $(seq 1 "$PASSES"); do
  printf '\n===== E2E %s pass %s/%s =====\n' "$PROFILE" "$pass" "$PASSES"
  DOTFILES_LOG_FILE="$ARTIFACT_DIR/bootstrap-pass-${pass}.log" \
    /dotfiles/scripts/install.sh \
    --source /dotfiles \
    --profile "$PROFILE" \
    --conflict-policy backup \
    --yes
  jq empty "$STATE_DIR/runs"/*/summary.json
done

latest_summary="$(find "$STATE_DIR/runs" -name summary.json -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
jq -e '.status == "success" and .duration_seconds >= 0' "$latest_summary" >/dev/null

ledger="$STATE_DIR/installed.tsv"
[[ -f "$ledger" ]] || {
  printf 'Managed-install ledger is missing\n' >&2
  exit 1
}
[[ "$(stat -c '%a' "$ledger")" == 600 ]] || {
  printf 'Ledger mode is not 600\n' >&2
  exit 1
}

for leaked_metadata in "$HOME/artifacts" "$HOME/docs"; do
  [[ ! -e "$leaked_metadata" ]] || {
    printf 'Repository metadata leaked into the target home: %s\n' "$leaked_metadata" >&2
    exit 1
  }
done

grep -Fxq 'history-sentinel' "$HOME/.zsh_history"
grep -Fxq '# e2e-local-sentinel' "$HOME/.config/dotfiles/local.zsh"
[[ "$(stat -c '%a' "$HOME/.config/dotfiles/local.zsh")" == 600 ]]

selected_sections="$(jq -r .sections "$latest_summary")"

manifest_version() {
  yq -r ".$1.$2" /dotfiles/packages.yaml
}

assert_version_contains() {
  local label="$1" expected="$2"
  shift 2
  local actual
  command -v "$1" >/dev/null 2>&1 || {
    printf '%s command is unavailable after installation: %s (PATH=%s)\n' \
      "$label" "$1" "$PATH" >&2
    exit 1
  }
  actual="$("$@" 2>&1)"
  [[ "$actual" == *"$expected"* ]] || {
    printf '%s version mismatch: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  }
}

if [[ ",$selected_sections," == *,terminal,* ]]; then
  assert_version_contains curlie "$(manifest_version core curlie)" curlie version
  printf '{"ready":true}\n' | gojq -e '.ready == true' >/dev/null
  [[ "$(printf 'pigz-smoke\n' | pigz | pigz -d)" == pigz-smoke ]]
  [[ "$(printf 'zstd-smoke\n' | zstd -q | zstd -dq)" == zstd-smoke ]]
fi

if [[ ",$selected_sections," == *,languages,* ]]; then
  assert_version_contains Go "$(manifest_version languages go)" go version
  assert_version_contains Rust "$(manifest_version languages rust)" rustc --version
  assert_version_contains Cargo "$(manifest_version languages cargo)" cargo --version
  assert_version_contains Node "$(manifest_version languages node)" node --version
  assert_version_contains npm "$(manifest_version languages npm)" npm --version
  assert_version_contains TypeScript "$(manifest_version languages typescript)" tsc --version
  python_path="$(uv python find "$(manifest_version languages python)")"
  assert_version_contains Python "$(manifest_version languages python)" "$python_path" --version
  assert_version_contains Java "$(manifest_version languages java | cut -d+ -f1)" java -version
fi

if [[ ",$selected_sections," == *,cloud,* ]]; then
  assert_version_contains kubectl "$(manifest_version cloud kubectl)" kubectl version --client
  assert_version_contains Helm "$(manifest_version cloud helm)" helm version --short
  assert_version_contains Terraform "$(manifest_version cloud terraform)" terraform version
  assert_version_contains k9s "$(manifest_version cloud k9s)" k9s version
  assert_version_contains AWS "$(manifest_version cloud aws_cli)" aws --version
  assert_version_contains cloudflared "$(manifest_version cloud cloudflared)" cloudflared --version
  assert_version_contains s5cmd "$(manifest_version cloud s5cmd)" s5cmd version
  kcat -V >/dev/null
  assert_version_contains stern "$(manifest_version cloud stern)" stern --version
  assert_version_contains helmfile "$(manifest_version cloud helmfile)" helmfile --version
  assert_version_contains kubectx "$(manifest_version cloud kubectx)" kubectx --version
  pgloader --version >/dev/null
  command -v gcloud >/dev/null
  command -v az >/dev/null
  command -v cloudflare-ssh >/dev/null
  cloudflare-ssh --help >/dev/null
  /dotfiles/tests/test-cloud-context-starship.sh /dotfiles
fi

if [[ ",$selected_sections," == *,ai,* ]]; then
  for agent in claude codex agy opencode omp; do
    command -v "$agent" >/dev/null
    "$agent" --version >/dev/null
  done
  assert_version_contains Serena "$(manifest_version ai_tools serena)" serena --version
  context_mode_manifest="$HOME/.local/share/npm/lib/node_modules/context-mode/package.json"
  [[ -f "$context_mode_manifest" ]]
  [[ "$(gojq -r '.version' "$context_mode_manifest")" == "$(manifest_version ai_tools context_mode)" ]]
  command -v agent-mcp >/dev/null
  mcp_status="$(agent-mcp status all)"
  if grep -Eq '[[:space:]]enabled$' <<<"$mcp_status"; then
    printf 'Optional MCP server was enabled without explicit user action:\n%s\n' "$mcp_status" >&2
    exit 1
  fi
  agent-mcp enable all --agent codex,claude,agy,opencode,omp >/dev/null
  mcp_status="$(agent-mcp status all)"
  enabled_count="$(grep -Ec '[[:space:]]enabled$' <<<"$mcp_status" || true)"
  if [[ "$enabled_count" -ne 10 ]]; then
    printf 'Expected 10 enabled agent/MCP registrations, got %s:\n%s\n' \
      "$enabled_count" "$mcp_status" >&2
    exit 1
  fi
  agent-mcp disable all --agent codex,claude,agy,opencode,omp >/dev/null
  mcp_status="$(agent-mcp status all)"
  if grep -Eq '[[:space:]]enabled$' <<<"$mcp_status"; then
    printf 'Optional MCP server remained enabled after cleanup:\n%s\n' "$mcp_status" >&2
    exit 1
  fi

  canonical_instructions="$HOME/.config/agents/AGENTS.md"
  [[ -f "$canonical_instructions" ]]
  for agent_instructions in \
    "$HOME/.codex/AGENTS.md" \
    "$HOME/.claude/CLAUDE.md" \
    "$HOME/.gemini/GEMINI.md" \
    "$HOME/.config/opencode/AGENTS.md" \
    "$HOME/.omp/agent/AGENTS.md"; do
    [[ -L "$agent_instructions" ]]
    [[ "$(readlink -f "$agent_instructions")" == "$(readlink -f "$canonical_instructions")" ]]
  done
  ! command -v gemini >/dev/null 2>&1
fi

if [[ "${DOTFILES_WSL:-false}" == true ]]; then
  [[ ! -e "$HOME/.config/kitty" ]] || {
    printf 'Native-only Kitty config was applied in WSL mode\n' >&2
    exit 1
  }
elif [[ ",$selected_sections," == *,desktop,* ]]; then
  [[ -f "$HOME/.config/kitty/kitty.conf" ]]
  kitty_version="$(
    awk '
      /^terminal:$/ { inside = 1; next }
      inside && $1 == "kitty:" {
        gsub(/["'\''"]/, "", $2)
        print $2
        exit
      }
    ' /dotfiles/packages.yaml
  )"
  kitty --version | grep -Fq "kitty $kitty_version "
  grep -Fq 'tab_bar_edge left' "$HOME/.config/kitty/kitty.conf"
else
  [[ -f "$HOME/.config/kitty/kitty.conf" ]]
  ! command -v kitty >/dev/null 2>&1
fi

if [[ ",$selected_sections," == *,system,* ]]; then
  command -v ssh-key-load >/dev/null
  ssh-key-load --help >/dev/null
  grep -Fq 'AddKeysToAgent 8h' "$HOME/.ssh/config"
  grep -Fq 'ProxyCommand %d/.local/bin/cloudflare-ssh proxy %h' "$HOME/.ssh/config"
  grep -Fq 'PreferredAuthentications publickey' "$HOME/.ssh/config"
  grep -Fq 'PasswordAuthentication no' "$HOME/.ssh/config"
fi

dot doctor --quick --sections "$selected_sections" >/dev/null

for log in "$ARTIFACT_DIR"/bootstrap-pass-*.log; do
  [[ "$(stat -c '%a' "$log")" == 600 ]] || {
    printf 'Log mode is not 600: %s\n' "$log" >&2
    exit 1
  }
  if LC_ALL=C grep -q $'\033' "$log"; then
    printf 'Persisted log contains ANSI escapes: %s\n' "$log" >&2
    exit 1
  fi
done

/dotfiles/tests/test-shell-performance.sh "$ARTIFACT_DIR/zsh-startup.json"

find "$STATE_DIR/logs" -name '*.jsonl' -exec sh -c 'while IFS= read -r line; do printf "%s" "$line" | jq -e . >/dev/null; done < "$1"' _ {} \;
collect_diagnostics 0
trap - EXIT
printf 'E2E profile %s passed (%s installation pass(es))\n' "$PROFILE" "$PASSES"
