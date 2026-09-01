#!/usr/bin/env bash
# Verify the CI benchmark emits normalized multi-scenario artifacts.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

command -v hyperfine >/dev/null 2>&1 || {
  printf 'hyperfine is required for benchmark tests\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'jq is required for benchmark tests\n' >&2
  exit 1
}
command -v yq >/dev/null 2>&1 || {
  printf 'yq is required for benchmark tests\n' >&2
  exit 1
}

OUTPUT_DIR="$TMP_ROOT/output"
DOTFILES_HYPERFINE_RUNS=2 DOTFILES_HYPERFINE_WARMUP_RUNS=0 \
  "$DOTFILES_DIR/scripts/hyperfine-benchmark.sh" \
  --output "$OUTPUT_DIR" --runs 2 --warmup 0 >/dev/null

for artifact in hyperfine.json hyperfine.md summary.json summary.md; do
  [[ -s "$OUTPUT_DIR/$artifact" ]] || {
    printf 'Missing benchmark artifact: %s\n' "$artifact" >&2
    exit 1
  }
done

jq -e '
  .schema_version == 2 and
  .tool == "hyperfine" and
  .runs == 2 and
  .warmup_runs == 0 and
  (.scenarios | length) == 5 and
  ([.scenarios[].name] | index("zsh startup (minimal fixture)")) != null and
  ([.scenarios[].median_ms] | all(. >= 0)) and
  ([.scenarios[].median_seconds] | all(. >= 0)) and
  ([.scenarios[].median_human] | all(type == "string" and length > 0)) and
  ([.scenarios[].samples_human] | all(length == 2))
' "$OUTPUT_DIR/summary.json" >/dev/null
grep -Fq 'zsh startup (minimal fixture)' "$OUTPUT_DIR/summary.md"
grep -Fq '| Scenario | Median | Mean | Minimum | Maximum |' "$OUTPUT_DIR/summary.md"
grep -Fq 'agent readiness (isolated)' "$OUTPUT_DIR/hyperfine.md"

printf 'Hyperfine benchmark test passed\n'
