#!/usr/bin/env bash
# Enforce a warm interactive zsh startup budget after a real bootstrap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
# shellcheck source=../scripts/performance-format.sh
source "$SCRIPT_DIR/performance-format.sh"

BUDGET_MS="${DOTFILES_ZSH_STARTUP_BUDGET_MS:-3000}"
REPORT_ONLY="${DOTFILES_PERFORMANCE_REPORT_ONLY:-false}"
ARTIFACT="${1:-/tmp/zsh-startup.json}"
DEBUG_DIR="${ARTIFACT%.json}-debug"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

command -v zsh >/dev/null 2>&1 || {
  printf 'zsh is unavailable\n' >&2
  exit 1
}
command -v script >/dev/null 2>&1 || {
  printf 'script(1) is unavailable for pseudo-terminal startup testing\n' >&2
  exit 1
}

run_zsh() {
  local transcript="$1"
  local status=0
  TERM=xterm-256color timeout 10 script -qefc 'zsh -lic exit' "$transcript" </dev/null >/dev/null || status=$?
  if [[ "$status" -ne 0 ]]; then
    rm -rf "$DEBUG_DIR"
    mkdir -p "$DEBUG_DIR"
    cp -a "$tmp"/. "$DEBUG_DIR/"
    ps -ef >"$DEBUG_DIR/processes.txt"
    printf 'zsh startup command failed with exit %s; diagnostics: %s\n' "$status" "$DEBUG_DIR" >&2
    return "$status"
  fi
}

run_zsh "$tmp/warmup.out"
if command -v hyperfine >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  cat >"$tmp/run-zsh-startup" <<'EOF'
#!/usr/bin/env bash
exec env TERM=xterm-256color timeout 10 script -qefc 'zsh -lic exit' "$1" </dev/null >/dev/null
EOF
  chmod +x "$tmp/run-zsh-startup"
  hyperfine_json="$tmp/hyperfine.json"
  startup_command="$(printf '%q %q' "$tmp/run-zsh-startup" "$tmp/hyperfine.out")"
  hyperfine --warmup "${DOTFILES_HYPERFINE_WARMUP_RUNS:-1}" \
    --runs "${DOTFILES_HYPERFINE_RUNS:-3}" \
    --export-json "$hyperfine_json" \
    "$startup_command" >/dev/null
  run_zsh "$tmp/validation.out"
  median="$(jq -r '.results[0].median * 1000 | round' "$hyperfine_json")"
  runs="$(jq -r '[.results[0].times[] * 1000 | round] | join(",")' "$hyperfine_json")"
else
  : >"$tmp/times"
  for run in 1 2 3; do
    started="$(date +%s%N)"
    run_zsh "$tmp/run-$run.out"
    ended="$(date +%s%N)"
    printf '%s\n' "$(((ended - started) / 1000000))" >>"$tmp/times"
  done
  median="$(sort -n "$tmp/times" | sed -n '2p')"
  runs="$(paste -sd, "$tmp/times")"
fi

mkdir -p "$(dirname "$ARTIFACT")"
budget_seconds="$(duration_ms_to_seconds "$BUDGET_MS")"
median_seconds="$(duration_ms_to_seconds "$median")"
budget_human="$(format_duration_ms "$BUDGET_MS")"
median_human="$(format_duration_ms "$median")"
jq -L "$SCRIPT_DIR" -n \
  --argjson budget_ms "$BUDGET_MS" \
  --argjson budget_seconds "$budget_seconds" \
  --arg budget_human "$budget_human" \
  --argjson median_ms "$median" \
  --argjson median_seconds "$median_seconds" \
  --arg median_human "$median_human" \
  --argjson runs_ms "[$runs]" \
  'include "performance-format";
  {
    schema_version: 2,
    budget_ms: $budget_ms,
    budget_seconds: $budget_seconds,
    budget_human: $budget_human,
    median_ms: $median_ms,
    median_seconds: $median_seconds,
    median_human: $median_human,
    runs_ms: $runs_ms,
    runs_seconds: [$runs_ms[] | . / 1000],
    runs_human: [$runs_ms[] | duration_human]
  }' >"$ARTIFACT"

if grep -Eaiq \
  'command not found|no such file or directory|can.t change option|plugin: .*not found|compinit:|(^|[^a-z])error:' \
  "$tmp"/*.out; then
  cat "$tmp"/*.out >&2
  printf 'zsh startup transcript contains errors\n' >&2
  exit 1
fi
if [[ "$median" -gt "$BUDGET_MS" ]]; then
  printf 'zsh startup median %s exceeded %s budget\n' \
    "$median_human" "$budget_human" >&2
  [[ "$REPORT_ONLY" == true ]] || exit 1
fi
printf 'zsh startup median: %s (budget %s)\n' "$median_human" "$budget_human"
