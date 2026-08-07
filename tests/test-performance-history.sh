#!/usr/bin/env bash
# Verify rolling performance aggregation, deduplication, and trend calculations.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/input/current" "$TMP_ROOT/input/prior" "$TMP_ROOT/output"

write_report() {
  local path="$1" generated="$2" run_id="$3" profile="$4" platform="$5" value="$6"
  jq -n \
    --arg generated "$generated" \
    --arg run_id "$run_id" \
    --arg profile "$profile" \
    --arg platform "$platform" \
    --argjson value "$value" \
    '{
      schema_version: 1,
      generated_at: $generated,
      context: {
        profile: $profile,
        platform: $platform,
        run_id: $run_id,
        run_attempt: "1",
        commit: $run_id
      },
      metrics: {
        zsh_startup: {value_ms: $value, budget_ms: 1000, status: "pass"},
        unavailable: {value_ms: null, budget_ms: 1, status: "unavailable"}
      }
    }' >"$path"
}

write_report "$TMP_ROOT/input/prior/performance.json" \
  2026-08-01T00:00:00Z run-1 base native 30
"$DOTFILES_DIR/scripts/performance-history.sh" \
  "$TMP_ROOT/input" "$TMP_ROOT/first" >/dev/null
cp "$TMP_ROOT/first/performance-history.json" \
  "$TMP_ROOT/input/prior/performance-history.json"

write_report "$TMP_ROOT/input/current/performance.json" \
  2026-08-02T00:00:00Z run-2 base native 50
"$DOTFILES_DIR/scripts/performance-history.sh" \
  "$TMP_ROOT/input" "$TMP_ROOT/output" >/dev/null

jq -e '
  .sample_count == 2 and
  (.samples | length) == 2 and
  (.series | length) == 1 and
  .series[0].profile == "base" and
  .series[0].platform == "native" and
  .series[0].metric == "zsh_startup" and
  .series[0].latest_ms == 50 and
  .series[0].previous_ms == 30 and
  .series[0].delta_ms == 20 and
  .series[0].median_ms == 40 and
  .series[0].min_ms == 30 and
  .series[0].max_ms == 50
' "$TMP_ROOT/output/performance-history.json" >/dev/null
grep -Fq '| `base` | `native` | `zsh_startup` | 50 ms | 30 ms | 20 ms |' \
  "$TMP_ROOT/output/performance-history.md"

printf 'Performance history test passed\n'
