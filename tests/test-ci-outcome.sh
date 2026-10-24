#!/usr/bin/env bash
# Verify CI result classification keeps code failures red and interruptions neutral.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
CLASSIFIER="$DOTFILES_DIR/scripts/classify-ci-run.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

assert_classification() {
  local expected_class="$1" expected_conclusion="$2" workflow_conclusion="$3" jobs="$4"
  local result
  printf '{"jobs":%s}\n' "$jobs" >"$TMP_ROOT/jobs.json"
  result="$($CLASSIFIER --jobs "$TMP_ROOT/jobs.json" --conclusion "$workflow_conclusion")"
  jq -e \
    --arg class "$expected_class" \
    --arg conclusion "$expected_conclusion" \
    '.classification == $class and .conclusion == $conclusion' \
    <<<"$result" >/dev/null
}

assert_classification success success success \
  '[{"conclusion":"success"},{"conclusion":"skipped"}]'
assert_classification code_failure failure failure \
  '[{"conclusion":"success"},{"conclusion":"failure"},{"conclusion":"cancelled"}]'
assert_classification infrastructure_cancelled neutral cancelled \
  '[{"conclusion":"success"},{"conclusion":"cancelled"},{"conclusion":"skipped"}]'
assert_classification infrastructure_cancelled neutral cancelled '[]'
assert_classification infrastructure_cancelled neutral cancelled \
  '[{"name":"Docker behavior","conclusion":"cancelled"},{"name":"CI Result","conclusion":"failure"}]'
assert_classification infrastructure_cancelled neutral cancelled \
  '[{"name":"Gated release and installer acceptance / Live Acceptance Result","conclusion":"failure"},{"name":"CI Result","conclusion":"failure"}]'
assert_classification code_failure failure cancelled \
  '[{"name":"Docker behavior","conclusion":"failure"},{"name":"CI Result","conclusion":"failure"}]'
assert_classification code_failure failure failure \
  '[{"name":"CI Result","conclusion":"failure"}]'
assert_classification success success success \
  '[{"name":"tests","conclusion":"success"},{"name":"CI Outcome Classification","conclusion":"failure"}]'

printf '%s\n' 'The hosted runner lost communication with the server.' >"$TMP_ROOT/run.log"
printf '{"jobs":[{"conclusion":"failure"}]}\n' >"$TMP_ROOT/jobs.json"
result="$($CLASSIFIER \
  --jobs "$TMP_ROOT/jobs.json" \
  --conclusion failure \
  --logs "$TMP_ROOT/run.log" \
  --run-url https://example.invalid/run/1)"
jq -e '
  .classification == "infrastructure_failure" and
  .conclusion == "neutral" and
  (.summary | contains("https://example.invalid/run/1"))
' <<<"$result" >/dev/null

printf '{"invalid":[]}\n' >"$TMP_ROOT/jobs.json"
if "$CLASSIFIER" --jobs "$TMP_ROOT/jobs.json" --conclusion failure >/dev/null 2>&1; then
  printf 'Invalid jobs input was accepted\n' >&2
  exit 1
fi

PUBLISHER="$DOTFILES_DIR/scripts/publish-ci-classification.sh"
export TMP_ROOT GITHUB_REPOSITORY=fixture/repository RUN_ID=200 RUN_ATTEMPT=2
printf -v HEAD_SHA '%040d' 1
export HEAD_SHA
jq -n --arg sha "$HEAD_SHA" '{workflow_runs:[
  {id:200,head_sha:$sha,status:"completed",run_number:20,run_attempt:2},
  {id:100,head_sha:$sha,status:"completed",run_number:10,run_attempt:5},
  {id:300,head_sha:$sha,status:"in_progress",run_number:30,run_attempt:1},
  {id:400,head_sha:"other",status:"completed",run_number:40,run_attempt:1}
]}' >"$TMP_ROOT/runs.json"
gh() {
  printf '%s\n' "$*" >>"$TMP_ROOT/gh-calls"
  case "${3:-}" in
    GET)
      [[ "${GH_METADATA_FAILURE:-false}" != true ]] || return 37
      if [[ "${GH_RUNS_EMPTY:-false}" == true ]]; then
        printf '{"workflow_runs":[]}\n'
        return 0
      fi
      cat "$TMP_ROOT/runs.json"
      ;;
    POST)
      cat >"$TMP_ROOT/published.json"
      printf '{}\n'
      ;;
    *) return 2 ;;
  esac
}
export -f gh
printf '{"jobs":[{"name":"tests","conclusion":"success"}]}\n' >"$TMP_ROOT/jobs.json"
"$CLASSIFIER" --jobs "$TMP_ROOT/jobs.json" --conclusion success >"$TMP_ROOT/classification.json"
"$PUBLISHER" "$TMP_ROOT/classification.json"
jq -e '.conclusion == "success" and .head_sha == env.HEAD_SHA and
  .name == "CI Outcome Classification" and
  (.details_url | endswith("/actions/runs/200"))' "$TMP_ROOT/published.json" >/dev/null
rm "$TMP_ROOT/published.json"

for superseded in '100 5' '200 1'; do
  read -r run_id attempt <<<"$superseded"
  RUN_ID="$run_id" RUN_ATTEMPT="$attempt" "$PUBLISHER" "$TMP_ROOT/classification.json"
  [[ ! -e "$TMP_ROOT/published.json" ]]
done
for failure in metadata empty-runs invalid-result wrong-sha; do
  case "$failure" in
    metadata)
      if GH_METADATA_FAILURE=true "$PUBLISHER" "$TMP_ROOT/classification.json"; then exit 1; fi
      ;;
    empty-runs)
      if GH_RUNS_EMPTY=true "$PUBLISHER" "$TMP_ROOT/classification.json"; then exit 1; fi
      ;;
    invalid-result)
      printf '{"conclusion":"unknown"}\n' >"$TMP_ROOT/invalid.json"
      if "$PUBLISHER" "$TMP_ROOT/invalid.json"; then exit 1; fi
      ;;
    wrong-sha)
      if HEAD_SHA=invalid "$PUBLISHER" "$TMP_ROOT/classification.json"; then exit 1; fi
      ;;
  esac
  [[ ! -e "$TMP_ROOT/published.json" ]]
done
printf '{"jobs":[{"name":"tests","conclusion":"failure"}]}\n' >"$TMP_ROOT/jobs.json"
"$CLASSIFIER" --jobs "$TMP_ROOT/jobs.json" --conclusion failure >"$TMP_ROOT/classification.json"
"$PUBLISHER" "$TMP_ROOT/classification.json"
jq -e '.conclusion == "failure"' "$TMP_ROOT/published.json" >/dev/null
printf '{"jobs":[{"name":"tests","conclusion":"cancelled"}]}\n' >"$TMP_ROOT/jobs.json"
"$CLASSIFIER" --jobs "$TMP_ROOT/jobs.json" --conclusion cancelled >"$TMP_ROOT/classification.json"
"$PUBLISHER" "$TMP_ROOT/classification.json"
jq -e '.conclusion == "neutral"' "$TMP_ROOT/published.json" >/dev/null

printf 'CI outcome classification test passed\n'
