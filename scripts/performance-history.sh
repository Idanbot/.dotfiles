#!/usr/bin/env bash
# Aggregate current performance samples and the previous rolling history artifact.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=performance-format.sh
source "$SCRIPT_DIR/performance-format.sh"

INPUT_DIR="${1:-}"
OUTPUT_DIR="${2:-}"

if [[ -z "$INPUT_DIR" || -z "$OUTPUT_DIR" ]]; then
  printf 'Usage: scripts/performance-history.sh INPUT_DIR OUTPUT_DIR\n' >&2
  exit 2
fi
[[ -d "$INPUT_DIR" ]] || {
  printf 'performance-history: input directory does not exist: %s\n' "$INPUT_DIR" >&2
  exit 2
}

mkdir -p "$OUTPUT_DIR"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
SAMPLES="$TMP_ROOT/samples.jsonl"
JSON_REPORT="$OUTPUT_DIR/performance-history.json"
MARKDOWN_REPORT="$OUTPUT_DIR/performance-history.md"
: >"$SAMPLES"

while IFS= read -r -d '' report; do
  if [[ "$(basename "$report")" == performance-history.json ]]; then
    jq -L "$SCRIPT_DIR" -c '
      include "performance-format";
      .samples[]? |
      .value_seconds = (.value_seconds // (.value_ms | duration_seconds)) |
      .value_human = (.value_human // (.value_ms | duration_human)) |
      .budget_seconds = (.budget_seconds // (.budget_ms | duration_seconds)) |
      .budget_human = (.budget_human // (.budget_ms | duration_human))
    ' "$report" >>"$SAMPLES"
    continue
  fi

  jq -L "$SCRIPT_DIR" -c --arg source "$report" '
    include "performance-format";
    . as $report |
    ($report.context // {}) as $context |
    ($report.metrics // {} | to_entries[]) |
    select(.value.value_ms | type == "number") |
    {
      id: ([
        ($context.run_id // "unknown"),
        ($context.run_attempt // "1"),
        ($context.profile // "unknown"),
        ($context.platform // "unknown"),
        .key,
        ($report.generated_at // $source)
      ] | join("|")),
      generated_at: ($report.generated_at // "unknown"),
      run_id: ($context.run_id // "unknown"),
      run_attempt: ($context.run_attempt // "1"),
      commit: ($context.commit // "unknown"),
      profile: ($context.profile // "unknown"),
      platform: ($context.platform // "unknown"),
      metric: .key,
      value_ms: .value.value_ms,
      value_seconds: (.value.value_seconds // (.value.value_ms | duration_seconds)),
      value_human: (.value.value_human // (.value.value_ms | duration_human)),
      budget_ms: .value.budget_ms,
      budget_seconds: (.value.budget_seconds // (.value.budget_ms | duration_seconds)),
      budget_human: (.value.budget_human // (.value.budget_ms | duration_human)),
      status: .value.status
    }
  ' "$report" >>"$SAMPLES"
done < <(
  find "$INPUT_DIR" -type f \
    \( -name performance.json -o -name performance-history.json \) \
    ! -path "$OUTPUT_DIR/*" -print0
)

if [[ -s "$SAMPLES" ]]; then
  jq -L "$SCRIPT_DIR" -s '
    include "performance-format";
    def median:
      sort as $values |
      ($values | length) as $count |
      if $count == 0 then null
      elif ($count % 2) == 1 then $values[($count / 2 | floor)]
      else ($values[(($count / 2) - 1)] + $values[($count / 2)]) / 2
      end;
    unique_by(.id) |
    sort_by(.generated_at, .run_id, .profile, .platform, .metric) as $samples |
    {
      schema_version: 2,
      generated_at: (now | todateiso8601),
      sample_count: ($samples | length),
      samples: $samples,
      series: (
        $samples |
        sort_by(.profile, .platform, .metric, .generated_at, .run_id) |
        group_by([.profile, .platform, .metric]) |
        map(
          . as $items |
          ($items | last) as $latest |
          ($items | if length > 1 then .[-2] else null end) as $previous |
          {
            profile: $latest.profile,
            platform: $latest.platform,
            metric: $latest.metric,
            count: ($items | length),
            latest_ms: $latest.value_ms,
            previous_ms: ($previous.value_ms // null),
            delta_ms: (
              if $previous == null then null
              else $latest.value_ms - $previous.value_ms
              end
            ),
            median_ms: ([$items[].value_ms] | median),
            min_ms: ([$items[].value_ms] | min),
            max_ms: ([$items[].value_ms] | max),
            budget_ms: $latest.budget_ms,
            latest_seconds: ($latest.value_ms | duration_seconds),
            previous_seconds: ($previous.value_ms | duration_seconds),
            delta_seconds: (
              if $previous == null then null
              else ($latest.value_ms - $previous.value_ms) / 1000
              end
            ),
            median_seconds: (([$items[].value_ms] | median) / 1000),
            min_seconds: (([$items[].value_ms] | min) / 1000),
            max_seconds: (([$items[].value_ms] | max) / 1000),
            budget_seconds: ($latest.budget_ms | duration_seconds),
            latest_human: ($latest.value_ms | duration_human),
            previous_human: ($previous.value_ms | duration_human),
            delta_human: (
              if $previous == null then "n/a"
              else (($latest.value_ms - $previous.value_ms) | duration_human)
              end
            ),
            median_human: (([$items[].value_ms] | median) | duration_human),
            min_human: (([$items[].value_ms] | min) | duration_human),
            max_human: (([$items[].value_ms] | max) | duration_human),
            budget_human: ($latest.budget_ms | duration_human),
            status: $latest.status,
            latest_run_id: $latest.run_id,
            latest_generated_at: $latest.generated_at
          }
        )
      )
    }
  ' "$SAMPLES" >"$JSON_REPORT"
else
  jq -L "$SCRIPT_DIR" -n '{
    schema_version: 2,
    generated_at: (now | todateiso8601),
    sample_count: 0,
    samples: [],
    series: []
  }' >"$JSON_REPORT"
fi

{
  printf '## Performance history\n\n'
  printf 'Rolling report-only trends from %s retained metric samples.\n\n' \
    "$(jq -r .sample_count "$JSON_REPORT")"
  if [[ "$(jq '.series | length' "$JSON_REPORT")" == 0 ]]; then
    printf 'No numeric performance samples are available.\n'
  else
    printf '| Profile | Platform | Metric | Latest | Previous | Delta | Median | Range | Budget | Status |\n'
    printf '|---|---|---|---:|---:|---:|---:|---:|---:|---|\n'
    while IFS=$'\t' read -r profile platform metric latest previous delta median minimum maximum budget status; do
      printf '| `%s` | `%s` | `%s` | %s | %s | %s | %s | %s to %s | %s | %s |\n' \
        "$profile" "$platform" "$metric" \
        "$(format_duration_ms "$latest")" "$(format_duration_ms "$previous")" \
        "$(format_duration_ms "$delta")" "$(format_duration_ms "$median")" \
        "$(format_duration_ms "$minimum")" "$(format_duration_ms "$maximum")" \
        "$(format_duration_ms "$budget")" "$status"
    done < <(
      jq -r '.series[] | [
        .profile, .platform, .metric, .latest_ms, .previous_ms,
        .delta_ms, .median_ms, .min_ms, .max_ms, .budget_ms, .status
      ] | @tsv' "$JSON_REPORT"
    )
  fi
} >"$MARKDOWN_REPORT"

chmod 644 "$JSON_REPORT" "$MARKDOWN_REPORT"
cat "$MARKDOWN_REPORT"
