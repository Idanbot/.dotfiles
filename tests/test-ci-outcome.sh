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

for conclusion in timed_out action_required startup_failure; do
  for workflow in failure cancelled; do
    assert_classification code_failure failure "$workflow" \
      "[{\"name\":\"acceptance\",\"conclusion\":\"$conclusion\"}]"
  done
done
for conclusion in skipped neutral; do
  assert_classification not_run neutral "$conclusion" \
    '[{"name":"tests","conclusion":"skipped"}]'
done
assert_classification infrastructure_cancelled neutral stale \
  '[{"name":"tests","conclusion":"stale"}]'
assert_classification unknown neutral success '[]'
assert_classification unknown neutral failure '[]'
assert_classification code_failure failure cancelled \
  '[{"name":"Custom CI Result","conclusion":"failure"}]'

printf '%s\n' '{"jobs":[
  {"name":"tests","conclusion":"success"},
  {"name":"CI Result","conclusion":"failure"},
  {"name":"optional","conclusion":"skipped"},
  {"name":"diagnostic","conclusion":"neutral"},
  {"name":"interrupted","conclusion":"stale"},
  {"name":"CI Outcome Classification","conclusion":"failure"}
]}' >"$TMP_ROOT/jobs.json"
result="$($CLASSIFIER --jobs "$TMP_ROOT/jobs.json" --conclusion cancelled \
  --logs "$TMP_ROOT/absent.log")"
jq -e '
  .classification == "infrastructure_cancelled" and .conclusion == "neutral" and
  .counts == {total:5,succeeded:1,failed:1,cancelled:1,skipped_or_neutral:2} and
  (.summary | contains("Aggregate result failures caused by cancellation were excluded"))
' <<<"$result" >/dev/null

printf '%s\n' 'The hosted runner lost communication with the server.' >"$TMP_ROOT/run.log"
printf '{"jobs":[{"conclusion":"failure"}]}\n' >"$TMP_ROOT/jobs.json"
result="$($CLASSIFIER \
  --jobs "$TMP_ROOT/jobs.json" \
  --conclusion failure \
  --logs "$TMP_ROOT/run.log" \
  --run-url https://example.invalid/run/1)"
jq -e '
  .classification == "code_failure" and
  .conclusion == "failure" and
  (.summary | contains("https://example.invalid/run/1"))
' <<<"$result" >/dev/null

printf '%s\n' '{"11":[{"annotation_level":"failure","message":"The hosted runner lost communication with the server."}]}' >"$TMP_ROOT/annotations.json"
printf '%s\n' '{"jobs":[{"id":11,"name":"runner","conclusion":"failure","steps":[{"name":"tests","conclusion":"cancelled"}]},
  {"id":12,"name":"CI Result","conclusion":"failure"}]}' >"$TMP_ROOT/jobs.json"
result="$($CLASSIFIER --jobs "$TMP_ROOT/jobs.json" --conclusion failure --annotations "$TMP_ROOT/annotations.json")"
jq -e '.classification == "infrastructure_failure" and .conclusion == "neutral"' <<<"$result" >/dev/null
jq '.jobs += [{id:13,name:"unit tests",conclusion:"failure",steps:[{name:"assertions",conclusion:"failure"}]}]' \
  "$TMP_ROOT/jobs.json" >"$TMP_ROOT/mixed.json"
result="$($CLASSIFIER --jobs "$TMP_ROOT/mixed.json" --conclusion failure --annotations "$TMP_ROOT/annotations.json")"
jq -e '.classification == "mixed_failure" and .conclusion == "failure"' <<<"$result" >/dev/null
jq '.jobs[0].conclusion = "cancelled"' "$TMP_ROOT/mixed.json" >"$TMP_ROOT/mixed-cancelled.json"
result="$($CLASSIFIER --jobs "$TMP_ROOT/mixed-cancelled.json" --conclusion cancelled --annotations "$TMP_ROOT/annotations.json")"
jq -e '.classification == "mixed_failure" and .conclusion == "failure"' <<<"$result" >/dev/null
for change in \
  '.jobs[0].steps[0].conclusion = "failure"' \
  '.jobs[0].steps[0] = {name:"Set up job",number:2,conclusion:"failure"}' \
  '.jobs[0].steps[0] = {name:"Complete job",number:3,conclusion:"failure"}' \
  '.jobs[0].id = 99'; do
  jq "$change" "$TMP_ROOT/jobs.json" >"$TMP_ROOT/ambiguous.json"
  result="$($CLASSIFIER --jobs "$TMP_ROOT/ambiguous.json" --conclusion failure --annotations "$TMP_ROOT/annotations.json")"
  jq -e '.conclusion == "failure"' <<<"$result" >/dev/null
done
jq '.jobs[0].steps[0] = {name:"Set up job",number:1,conclusion:"failure"}' \
  "$TMP_ROOT/jobs.json" >"$TMP_ROOT/setup-outage.json"
result="$($CLASSIFIER --jobs "$TMP_ROOT/setup-outage.json" --conclusion failure --annotations "$TMP_ROOT/annotations.json")"
jq -e '.classification == "infrastructure_failure" and .conclusion == "neutral"' <<<"$result" >/dev/null
for annotations in '{}' '{"11":[]}' '{"11":[{"annotation_level":"failure","message":"fixture: The hosted runner lost communication with the server."}]}'; do
  printf '%s\n' "$annotations" >"$TMP_ROOT/ambiguous-annotations.json"
  result="$($CLASSIFIER --jobs "$TMP_ROOT/jobs.json" --conclusion failure --annotations "$TMP_ROOT/ambiguous-annotations.json")"
  jq -e '.conclusion == "failure"' <<<"$result" >/dev/null
done
result="$($CLASSIFIER --jobs "$TMP_ROOT/jobs.json" --conclusion failure --annotations "$TMP_ROOT/missing-annotations.json")"
jq -e '.conclusion == "failure"' <<<"$result" >/dev/null
jq '.jobs |= map(.conclusion = "success")' "$TMP_ROOT/jobs.json" >"$TMP_ROOT/rerun.json"
result="$($CLASSIFIER --jobs "$TMP_ROOT/rerun.json" --conclusion success --annotations "$TMP_ROOT/annotations.json")"
jq -e '.classification == "success" and .conclusion == "success"' <<<"$result" >/dev/null

# Exercise the actual workflow collector with paginated jobs and mocked GitHub.
python3 - "$DOTFILES_DIR" "$TMP_ROOT" <<'PY'
from pathlib import Path
import sys
import yaml
root, temporary = map(Path, sys.argv[1:])
workflow = yaml.safe_load((root / ".github/workflows/ci-outcome.yml").read_text())
step = next(step for step in workflow["jobs"]["classify"]["steps"]
            if step["name"] == "Fetch jobs and job-scoped infrastructure annotations")
(temporary / "collect.sh").write_text("set -euo pipefail\n" + step["run"])
PY
(
  gh() {
    case "$*" in
      *'/actions/runs/'*)
        printf '%s\n' '[{"jobs":[{"id":11,"conclusion":"failure","check_run_url":"https://api.github.com/repos/fixture/repository/check-runs/31"}]},{"jobs":[{"id":22,"conclusion":"success"}]}]'
        ;;
      *'/check-runs/31/annotations?'*)
        [[ "${ANNOTATION_FAILURE:-false}" != true ]] || return 37
        printf '%s\n' '[[{"annotation_level":"failure","message":"The hosted runner lost communication with the server."}]]'
        ;;
      *) return 9 ;;
    esac
  }
  export -f gh
  export RUNNER_TEMP="$TMP_ROOT/collector" RUN_CONCLUSION=failure RUN_ID=1 GITHUB_REPOSITORY=fixture/repository
  mkdir "$RUNNER_TEMP"
  bash "$TMP_ROOT/collect.sh"
  jq -e '.jobs | length == 2' "$RUNNER_TEMP/jobs.json" >/dev/null
  jq -e '."11"[0].annotation_level == "failure"' "$RUNNER_TEMP/annotations.json" >/dev/null
  ANNOTATION_FAILURE=true bash "$TMP_ROOT/collect.sh" >"$TMP_ROOT/collector-warning"
  jq -e '. == {}' "$RUNNER_TEMP/annotations.json" >/dev/null
  grep -q 'failures will remain actionable' "$TMP_ROOT/collector-warning"
)

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
  {id:900,head_sha:$sha,status:"completed",run_number:10,run_attempt:5},
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
      [[ "${GH_PUBLISH_FAILURE:-false}" != true ]] || return 41
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

for superseded in '900 5' '200 1'; do
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

rm "$TMP_ROOT/published.json"
if GH_PUBLISH_FAILURE=true "$PUBLISHER" "$TMP_ROOT/classification.json"; then
  printf 'GitHub check publication failure was ignored\n' >&2
  exit 1
else
  [[ "$?" == 41 ]]
fi
[[ ! -e "$TMP_ROOT/published.json" ]]

for invalid in HEAD_SHA= RUN_ID=0 RUN_ID=-1 RUN_ID=abc RUN_ATTEMPT=0 RUN_ATTEMPT=abc \
  GITHUB_REPOSITORY=fixture GITHUB_REPOSITORY=fixture/repo/extra; do
  : >"$TMP_ROOT/gh-calls"
  if env "$invalid" "$PUBLISHER" "$TMP_ROOT/classification.json" \
    >"$TMP_ROOT/rejection.log" 2>&1; then
    printf 'Invalid publication input accepted: %s\n' "$invalid" >&2
    exit 1
  fi
  [[ ! -s "$TMP_ROOT/gh-calls" && ! -e "$TMP_ROOT/published.json" ]]
done

for invalid in '{' '{}' '{"conclusion":"success","title":1,"summary":"text"}' \
  '{"conclusion":"success","title":"text"}' \
  '{"conclusion":"success","title":"text","summary":null}'; do
  printf '%s\n' "$invalid" >"$TMP_ROOT/invalid.json"
  : >"$TMP_ROOT/gh-calls"
  if "$PUBLISHER" "$TMP_ROOT/invalid.json" >"$TMP_ROOT/rejection.log" 2>&1; then
    printf 'Malformed classification result was accepted: %s\n' "$invalid" >&2
    exit 1
  fi
  ! grep -q POST "$TMP_ROOT/gh-calls"
  [[ ! -e "$TMP_ROOT/published.json" ]]
done

cp "$TMP_ROOT/runs.json" "$TMP_ROOT/valid-runs.json"
for invalid in '{' '{}' '{"workflow_runs":null}'; do
  printf '%s\n' "$invalid" >"$TMP_ROOT/runs.json"
  : >"$TMP_ROOT/gh-calls"
  if "$PUBLISHER" "$TMP_ROOT/classification.json" >"$TMP_ROOT/rejection.log" 2>&1; then
    printf 'Malformed run metadata was accepted: %s\n' "$invalid" >&2
    exit 1
  fi
  ! grep -q POST "$TMP_ROOT/gh-calls"
  [[ ! -e "$TMP_ROOT/published.json" ]]
done
cp "$TMP_ROOT/valid-runs.json" "$TMP_ROOT/runs.json"

jq -n --arg title 'A "quoted" title' --arg summary $'First line\nSecond line: "quoted" \\ path' \
  '{conclusion:"success",title:$title,summary:$summary,head_sha:"untrusted",name:"untrusted"}' \
  >"$TMP_ROOT/escaped.json"
RUN_URL='https://example.invalid/run/200?attempt=2&view=checks' \
  "$PUBLISHER" "$TMP_ROOT/escaped.json"
jq -e --slurpfile source "$TMP_ROOT/escaped.json" '
  .output == {title:$source[0].title,summary:$source[0].summary} and
  .head_sha == env.HEAD_SHA and .name == "CI Outcome Classification" and
  .status == "completed" and .conclusion == "success" and
  .details_url == "https://example.invalid/run/200?attempt=2&view=checks"
' "$TMP_ROOT/published.json" >/dev/null
rm "$TMP_ROOT/published.json"

# Legacy run metadata omits run_attempt; the API contract defaults it to one.
jq '.workflow_runs |= map(del(.run_attempt))' "$TMP_ROOT/valid-runs.json" >"$TMP_ROOT/runs.json"
RUN_ATTEMPT=1 "$PUBLISHER" "$TMP_ROOT/escaped.json"
jq -e '.conclusion == "success"' "$TMP_ROOT/published.json" >/dev/null
rm "$TMP_ROOT/published.json"

# A newer failed workflow must replace a previous success, not be filtered out.
jq --arg sha "$HEAD_SHA" '.workflow_runs += [
  {id:500,head_sha:$sha,status:"completed",run_number:25,run_attempt:1,conclusion:"failure"}
]' "$TMP_ROOT/valid-runs.json" >"$TMP_ROOT/runs.json"
"$PUBLISHER" "$TMP_ROOT/escaped.json"
[[ ! -e "$TMP_ROOT/published.json" ]]
printf '{"jobs":[{"name":"tests","conclusion":"failure"}]}\n' >"$TMP_ROOT/jobs.json"
"$CLASSIFIER" --jobs "$TMP_ROOT/jobs.json" --conclusion failure >"$TMP_ROOT/classification.json"
RUN_ID=500 RUN_ATTEMPT=1 "$PUBLISHER" "$TMP_ROOT/classification.json"
jq -e '.conclusion == "failure" and (.details_url | endswith("/actions/runs/500"))' \
  "$TMP_ROOT/published.json" >/dev/null

printf 'CI outcome classification test passed\n'
