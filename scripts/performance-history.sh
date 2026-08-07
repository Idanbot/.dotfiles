#!/usr/bin/env bash
# Aggregate current performance samples and the previous rolling history artifact.

set -euo pipefail

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
    jq -c '.samples[]?' "$report" >>"$SAMPLES"
    continue
  fi

  jq -c --arg source "$report" '
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
      budget_ms: .value.budget_ms,
      status: .value.status
    }
  ' "$report" >>"$SAMPLES"
done < <(
  find "$INPUT_DIR" -type f \
    \( -name performance.json -o -name performance-history.json \) \
    ! -path "$OUTPUT_DIR/*" -print0
)

if [[ -s "$SAMPLES" ]]; then
  jq -s '
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
      schema_version: 1,
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
            status: $latest.status,
            latest_run_id: $latest.run_id,
            latest_generated_at: $latest.generated_at
          }
        )
      )
    }
  ' "$SAMPLES" >"$JSON_REPORT"
else
  jq -n '{
    schema_version: 1,
    generated_at: (now | todateiso8601),
    sample_count: 0,
    samples: [],
    series: []
  }' >"$JSON_REPORT"
fi

display_ms() {
  [[ "$1" == null ]] && printf 'n/a' || printf '%s ms' "$1"
}

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
      printf '| `%s` | `%s` | `%s` | %s | %s | %s | %s | %s-%s ms | %s | %s |\n' \
        "$profile" "$platform" "$metric" \
        "$(display_ms "$latest")" "$(display_ms "$previous")" "$(display_ms "$delta")" \
        "$(display_ms "$median")" "$minimum" "$maximum" "$(display_ms "$budget")" "$status"
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
