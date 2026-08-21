#!/usr/bin/env bash
# Benchmark representative dotfiles commands without touching user or cloud state.

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${DOTFILES_BENCHMARK_OUTPUT:-/tmp/dotfiles-hyperfine}"
RUNS="${DOTFILES_HYPERFINE_RUNS:-5}"
WARMUP="${DOTFILES_HYPERFINE_WARMUP_RUNS:-1}"

usage() {
  cat <<'USAGE'
Usage: scripts/hyperfine-benchmark.sh [options]

  --output DIR   Write Hyperfine and summary artifacts to DIR.
  --runs N       Number of measured runs per scenario (default: 5).
  --warmup N     Number of warmup runs (default: 1).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --output=*)
      OUTPUT_DIR="${1#--output=}"
      shift
      ;;
    --runs)
      RUNS="${2:-}"
      shift 2
      ;;
    --runs=*)
      RUNS="${1#--runs=}"
      shift
      ;;
    --warmup)
      WARMUP="${2:-}"
      shift 2
      ;;
    --warmup=*)
      WARMUP="${1#--warmup=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || {
  printf 'runs must be a positive integer\n' >&2
  exit 2
}
[[ "$WARMUP" =~ ^[0-9]+$ ]] || {
  printf 'warmup must be a non-negative integer\n' >&2
  exit 2
}
command -v hyperfine >/dev/null 2>&1 || {
  printf 'hyperfine is required for benchmark scenarios\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'jq is required to normalize Hyperfine results\n' >&2
  exit 1
}
command -v zsh >/dev/null 2>&1 || {
  printf 'zsh is required for startup benchmarks\n' >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
fixture_home="$tmp_root/home"
fixture_zdotdir="$tmp_root/zsh"
fixture_registry="$tmp_root/agents.yaml"
mkdir -p "$fixture_home" "$fixture_zdotdir"

cat >"$fixture_zdotdir/.zshrc" <<'EOF'
setopt no_beep prompt_subst
autoload -Uz compinit
EOF
cat >"$fixture_registry" <<'EOF'
workspace:
  agents:
    - shell
agents:
  shell:
    command: sh
    required: true
EOF

quote() { printf '%q' "$1"; }
dotfiles_q="$(quote "$DOTFILES_DIR")"
home_q="$(quote "$fixture_home")"
registry_q="$(quote "$fixture_registry")"
cloud_context_q="$(quote "$DOTFILES_DIR/dot_local/bin/executable_cloud-context")"
agent_status_q="$(quote "$DOTFILES_DIR/dot_local/bin/executable_dot-agent-status")"
workspace_q="$(quote "$DOTFILES_DIR/dot_local/bin/executable_dot-workspace")"
zsh_dir_q="$(quote "$fixture_zdotdir")"

hyperfine_args=(
  --warmup "$WARMUP"
  --runs "$RUNS"
  --export-json "$OUTPUT_DIR/hyperfine.json"
  --export-markdown "$OUTPUT_DIR/hyperfine.md"
  --command-name 'installer help'
  "$dotfiles_q/scripts/install.sh --help"
  --command-name 'workspace help'
  "$workspace_q --help"
  --command-name 'cloud context status (isolated)'
  "HOME=$home_q XDG_CONFIG_HOME=$home_q/.config XDG_STATE_HOME=$home_q/.local/state PATH=/usr/bin:/bin $cloud_context_q --status"
  --command-name 'agent readiness (isolated)'
  "HOME=$home_q PATH=/usr/bin:/bin $agent_status_q --registry $registry_q --compact"
  --command-name 'zsh startup (minimal fixture)'
  "HOME=$home_q ZDOTDIR=$zsh_dir_q TERM=xterm-256color zsh -lic exit"
)
hyperfine "${hyperfine_args[@]}"

jq --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg commit "${GITHUB_SHA:-local}" \
  --arg runs "$RUNS" \
  --arg warmup "$WARMUP" \
  '{
    schema_version: 1,
    tool: "hyperfine",
    generated_at: $generated_at,
    commit: $commit,
    runs: ($runs | tonumber),
    warmup_runs: ($warmup | tonumber),
    scenarios: [.results[] | {
      name: .command,
      mean_ms: (.mean * 1000 | round),
      median_ms: (.median * 1000 | round),
      min_ms: (.min * 1000 | round),
      max_ms: (.max * 1000 | round),
      samples: ([.times[] * 1000 | round])
    }]
  }' "$OUTPUT_DIR/hyperfine.json" >"$OUTPUT_DIR/summary.json"

{
  printf '## Hyperfine benchmark scenarios\n\n'
  printf 'Runs: `%s` | Warmups: `%s` | Commit: `%s`\n\n' \
    "$RUNS" "$WARMUP" "${GITHUB_SHA:-local}"
  printf '| Scenario | Median | Mean | Range |\n|---|---:|---:|---:|\n'
  jq -r '.scenarios[] | "| `\(.name)` | \(.median_ms) ms | \(.mean_ms) ms | \(.min_ms)-\(.max_ms) ms |"' \
    "$OUTPUT_DIR/summary.json"
} >"$OUTPUT_DIR/summary.md"

cat "$OUTPUT_DIR/summary.md"
