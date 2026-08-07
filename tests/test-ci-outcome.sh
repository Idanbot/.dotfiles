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

printf 'CI outcome classification test passed\n'
