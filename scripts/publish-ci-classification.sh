#!/usr/bin/env bash
# Publish only the newest completed bootstrap attempt for this commit.
set -euo pipefail
classification="${1:?usage: publish-ci-classification.sh CLASSIFICATION.json}"
[[ "${HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ && "${RUN_ID:-}" =~ ^[1-9][0-9]*$ &&
  "${RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ &&
  "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  printf 'Invalid classification publication inputs\n' >&2
  exit 2
}
latest="$(gh api --method GET \
  "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml/runs?head_sha=$HEAD_SHA&per_page=100" |
  jq -er --arg sha "$HEAD_SHA" '
    [.workflow_runs[] | select(.head_sha == $sha and .status == "completed")] |
    if length == 0 then error("No completed bootstrap run for this commit")
    else max_by([.run_number, (.run_attempt // 1)]) |
      [.id, (.run_attempt // 1)] | @tsv end')"
if [[ "$latest" != "$RUN_ID"$'\t'"$RUN_ATTEMPT" ]]; then
  printf 'Skipping superseded classification for run %s attempt %s\n' "$RUN_ID" "$RUN_ATTEMPT"
  exit 0
fi
payload="$(jq -e --arg sha "$HEAD_SHA" \
  --arg url "${RUN_URL:-https://github.com/$GITHUB_REPOSITORY/actions/runs/$RUN_ID}" '
  if (.conclusion == "success" or .conclusion == "failure" or .conclusion == "neutral") and
      (.title | type == "string") and (.summary | type == "string") then
    {name: "CI Outcome Classification", head_sha: $sha, status: "completed",
     conclusion: .conclusion, details_url: $url, output: {title: .title, summary: .summary}}
  else error("Invalid classification result") end' "$classification")"
printf '%s\n' "$payload" |
  gh api --method POST "repos/$GITHUB_REPOSITORY/check-runs" --input - >/dev/null
