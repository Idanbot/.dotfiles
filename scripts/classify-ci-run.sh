#!/usr/bin/env bash
# Classify a completed CI run without turning infrastructure interruptions into code failures.

set -euo pipefail

JOBS_FILE=""
ANNOTATIONS_FILE=""
WORKFLOW_CONCLUSION=""
RUN_URL=""

usage() {
  cat <<'EOF'
Usage: scripts/classify-ci-run.sh --jobs FILE --conclusion VALUE [options]

Options:
  --jobs FILE          GitHub Actions jobs API response ({"jobs": [...]})
  --conclusion VALUE   Completed workflow conclusion
  --annotations FILE   Optional object mapping job IDs to GitHub check annotations
  --logs FILE          Legacy argument; combined logs never excuse failed jobs
  --run-url URL        Optional workflow URL included in the summary
  -h, --help           Show this help

The command writes one JSON object containing classification, check conclusion,
title, summary, and job counts. Exit status is nonzero only for invalid input.
EOF
}

while (($#)); do
  case "$1" in
    --jobs)
      JOBS_FILE="${2:-}"
      shift 2
      ;;
    --conclusion)
      WORKFLOW_CONCLUSION="${2:-}"
      shift 2
      ;;
    --logs)
      shift 2
      ;;
    --annotations)
      ANNOTATIONS_FILE="${2:-}"
      shift 2
      ;;
    --run-url)
      RUN_URL="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'classify-ci-run: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

[[ -n "$JOBS_FILE" && -r "$JOBS_FILE" ]] || {
  printf 'classify-ci-run: --jobs must name a readable file\n' >&2
  exit 2
}
[[ -n "$WORKFLOW_CONCLUSION" ]] || {
  printf 'classify-ci-run: --conclusion is required\n' >&2
  exit 2
}
jq -e '.jobs | type == "array"' "$JOBS_FILE" >/dev/null || {
  printf 'classify-ci-run: jobs input must contain a jobs array\n' >&2
  exit 2
}

count_conclusion() {
  jq --arg conclusion "$1" '[.jobs[] | select(.name != "CI Outcome Classification" and .conclusion == $conclusion)] | length' "$JOBS_FILE"
}

total="$(jq '[.jobs[] | select(.name != "CI Outcome Classification")] | length' "$JOBS_FILE")"
succeeded="$(count_conclusion success)"
failed="$(jq '[.jobs[] | select(.name != "CI Outcome Classification") | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure")] | length' "$JOBS_FILE")"
cancelled="$(jq '[.jobs[] | select(.name != "CI Outcome Classification") | select(.conclusion == "cancelled" or .conclusion == "stale")] | length' "$JOBS_FILE")"
skipped="$(jq '[.jobs[] | select(.name != "CI Outcome Classification") | select(.conclusion == "skipped" or .conclusion == "neutral")] | length' "$JOBS_FILE")"
annotations='{}'
if [[ -n "$ANNOTATIONS_FILE" && -r "$ANNOTATIONS_FILE" ]]; then
  jq -e 'type == "object" and all(.[]; type == "array")' "$ANNOTATIONS_FILE" >/dev/null || {
    printf 'classify-ci-run: annotations must map job IDs to arrays\n' >&2
    exit 2
  }
  annotations="$(jq -c . "$ANNOTATIONS_FILE")"
fi

# Platform annotations are scoped to a job. A failed test step always wins over
# an outage annotation, and missing/ambiguous evidence never excuses a failure.
failure_evidence="$(jq -c --argjson annotations "$annotations" --arg workflow "$WORKFLOW_CONCLUSION" '
  def failed: .conclusion == "failure" or .conclusion == "timed_out" or
    .conclusion == "action_required" or .conclusion == "startup_failure";
  def aggregate: .name == "CI Result" or
    .name == "Gated release and installer acceptance / Live Acceptance Result";
  [.jobs[] | select(.name != "CI Outcome Classification") | select(failed)] as $failed |
  [$failed[] | select(aggregate | not)] as $leaves |
  (if ($leaves | length) > 0 or $workflow == "cancelled"
    then $leaves else $failed end) +
    [.jobs[] | select(.name != "CI Outcome Classification") |
      select(.conclusion == "cancelled" or .conclusion == "stale")] |
  map(. as $job | {
    failed: ($job | failed),
    infrastructure: (
      ($job.id | type) == "number" and
      ($job.steps | type) == "array" and
      ([$job.steps[]? | select(failed) |
        select(.name != "Set up job" and .name != "Complete job")] | length) == 0 and
      any($annotations[($job.id | tostring)][]?;
        type == "object" and .annotation_level == "failure" and
        (.message | type) == "string" and
        (.message | test("^(The )?(hosted runner lost communication with the server|runner process is not responding|runner has received a shutdown signal|no available hosted runners|runner was terminated by the operating system)|^The runner: [^\\r\\n]+ lost communication with the server"; "i"))))
  })
' "$JOBS_FILE")"
actionable_failed="$(jq '[.[] | select(.failed and (.infrastructure | not))] | length' <<<"$failure_evidence")"
infrastructure_failed="$(jq '[.[] | select(.infrastructure)] | length' <<<"$failure_evidence")"

classification=unknown
check_conclusion=neutral
title="CI outcome requires review"
reason="The workflow conclusion and job conclusions did not match a known state."

if ((actionable_failed > 0 && infrastructure_failed > 0)); then
  classification=mixed_failure
  check_conclusion=failure
  title="Actionable CI failure with infrastructure interruption"
  reason="$actionable_failed job(s) have actionable or unverified failures; $infrastructure_failed other job(s) have job-scoped runner-outage evidence."
elif ((actionable_failed > 0)); then
  classification=code_failure
  check_conclusion=failure
  title="Actionable CI failure"
  reason="At least one job failed without trustworthy job-scoped infrastructure-only evidence. Combined logs cannot excuse failures."
elif ((infrastructure_failed > 0)); then
  classification=infrastructure_failure
  check_conclusion=neutral
  title="Infrastructure failure"
  reason="All $infrastructure_failed infrastructure-only job(s) have job-scoped GitHub runner-outage annotations and no failed test steps."
elif ((cancelled > 0)) || [[ "$WORKFLOW_CONCLUSION" == cancelled || "$WORKFLOW_CONCLUSION" == stale ]]; then
  classification=infrastructure_cancelled
  check_conclusion=neutral
  title="Infrastructure interruption"
  reason="The run was cancelled without an actionable job failure. Re-run it before changing code."
  if ((failed > actionable_failed)); then
    reason+=" Aggregate result failures caused by cancellation were excluded."
  fi
elif [[ "$WORKFLOW_CONCLUSION" == success ]] && ((total > 0)); then
  classification=success
  check_conclusion=success
  title="CI completed successfully"
  reason="Every completed job passed or was intentionally skipped."
elif [[ "$WORKFLOW_CONCLUSION" == skipped || "$WORKFLOW_CONCLUSION" == neutral ]]; then
  classification=not_run
  check_conclusion=neutral
  title="CI did not run"
  reason="The workflow completed without executing an actionable test path."
fi

summary="Classification: ${classification}. Workflow: ${WORKFLOW_CONCLUSION}. Jobs: ${total} total, ${succeeded} passed, ${failed} failed, ${cancelled} cancelled, ${skipped} skipped/neutral. ${reason}"
if [[ -n "$RUN_URL" ]]; then
  summary+=" Run: ${RUN_URL}"
fi

jq -n \
  --arg classification "$classification" \
  --arg conclusion "$check_conclusion" \
  --arg title "$title" \
  --arg summary "$summary" \
  --argjson total "$total" \
  --argjson succeeded "$succeeded" \
  --argjson failed "$failed" \
  --argjson cancelled "$cancelled" \
  --argjson skipped "$skipped" \
  '{
    classification: $classification,
    conclusion: $conclusion,
    title: $title,
    summary: $summary,
    counts: {
      total: $total,
      succeeded: $succeeded,
      failed: $failed,
      cancelled: $cancelled,
      skipped_or_neutral: $skipped
    }
  }'
