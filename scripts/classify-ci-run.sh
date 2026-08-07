#!/usr/bin/env bash
# Classify a completed CI run without turning infrastructure interruptions into code failures.

set -euo pipefail

JOBS_FILE=""
LOG_FILE=""
WORKFLOW_CONCLUSION=""
RUN_URL=""

usage() {
  cat <<'EOF'
Usage: scripts/classify-ci-run.sh --jobs FILE --conclusion VALUE [options]

Options:
  --jobs FILE          GitHub Actions jobs API response ({"jobs": [...]})
  --conclusion VALUE   Completed workflow conclusion
  --logs FILE          Optional combined job log used for runner-outage signatures
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
      LOG_FILE="${2:-}"
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
  jq --arg conclusion "$1" '[.jobs[] | select(.conclusion == $conclusion)] | length' "$JOBS_FILE"
}

total="$(jq '.jobs | length' "$JOBS_FILE")"
succeeded="$(count_conclusion success)"
failed="$(jq '[.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure")] | length' "$JOBS_FILE")"
cancelled="$(jq '[.jobs[] | select(.conclusion == "cancelled" or .conclusion == "stale")] | length' "$JOBS_FILE")"
skipped="$(jq '[.jobs[] | select(.conclusion == "skipped" or .conclusion == "neutral")] | length' "$JOBS_FILE")"

infra_signature=""
if [[ -n "$LOG_FILE" && -r "$LOG_FILE" ]]; then
  infra_signature="$({
    grep -Eim1 \
      'hosted runner lost communication|runner process is not responding|runner has received a shutdown signal|no available hosted runners|lost communication with the server|runner was terminated by the operating system' \
      "$LOG_FILE" || true
  } | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
fi

classification=unknown
check_conclusion=neutral
title="CI outcome requires review"
reason="The workflow conclusion and job conclusions did not match a known state."

if ((failed > 0)) && [[ -z "$infra_signature" ]]; then
  classification=code_failure
  check_conclusion=failure
  title="Actionable CI failure"
  reason="At least one job failed, timed out, or could not start without a known runner-outage signature."
elif ((failed > 0)) && [[ -n "$infra_signature" ]]; then
  classification=infrastructure_failure
  check_conclusion=neutral
  title="Infrastructure failure"
  reason="A failed job contained a known GitHub-hosted runner outage signature: $infra_signature"
elif ((cancelled > 0)) || [[ "$WORKFLOW_CONCLUSION" == cancelled || "$WORKFLOW_CONCLUSION" == stale ]]; then
  classification=infrastructure_cancelled
  check_conclusion=neutral
  title="Infrastructure interruption"
  reason="The run was cancelled without an actionable job failure. Re-run it before changing code."
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
