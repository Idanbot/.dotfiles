#!/usr/bin/env bash
# Verify concise and JUnit E2E reports preserve actionable failure context.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ARTIFACT_DIR="$TMP_ROOT/artifacts"
STATE_DIR="$TMP_ROOT/state"
RUN_ID=20260730T120000Z-42

mkdir -p "$ARTIFACT_DIR" "$STATE_DIR/logs" "$STATE_DIR/runs/$RUN_ID"
cat >"$STATE_DIR/logs/bootstrap-$RUN_ID.jsonl" <<EOF
{"time":"2026-07-30T12:00:00Z","run_id":"$RUN_ID","stage":"section-cloud","level":"start","message":"stage started"}
{"time":"2026-07-30T12:00:01Z","run_id":"$RUN_ID","stage":"section-cloud","level":"error","message":"failed line=882 exit=17"}
EOF
cat >"$STATE_DIR/runs/$RUN_ID/summary.json" <<EOF
{"run_id":"$RUN_ID","status":"failure","duration_seconds":12}
EOF
cat >"$ARTIFACT_DIR/bootstrap-pass-2.log" <<'EOF'
Installing cloud tools
API_KEY=do-not-publish
apt dependency resolution failed
EOF

"$DOTFILES_DIR/scripts/e2e-report.sh" \
  --artifacts "$ARTIFACT_DIR" \
  --state "$STATE_DIR" \
  --status 17 \
  --profile cloud \
  --platform wsl \
  --passes 2 \
  --current-pass 2 >/dev/null

grep -Fq 'E2E result: FAIL' "$ARTIFACT_DIR/e2e-report.txt"
grep -Fq 'Stage: section-cloud' "$ARTIFACT_DIR/e2e-report.txt"
grep -Fq '/dotfiles/scripts/install.sh --source /dotfiles --profile cloud' \
  "$ARTIFACT_DIR/e2e-report.txt"
grep -Fq "/dotfiles/scripts/install.sh --resume=$RUN_ID" "$ARTIFACT_DIR/e2e-report.txt"
grep -Fq 'API_KEY=[REDACTED]' "$ARTIFACT_DIR/e2e-report.txt"
! grep -Fq 'do-not-publish' "$ARTIFACT_DIR/e2e-report.txt"
! grep -Fq 'do-not-publish' "$ARTIFACT_DIR/e2e-results.xml"
grep -Fq '<testsuite name="dotfiles-e2e" tests="1" failures="1"' \
  "$ARTIFACT_DIR/e2e-results.xml"
grep -Fq 'classname="bootstrap.cloud"' "$ARTIFACT_DIR/e2e-results.xml"

"$DOTFILES_DIR/scripts/e2e-report.sh" \
  --artifacts "$ARTIFACT_DIR" \
  --state "$STATE_DIR" \
  --status 0 \
  --profile cloud \
  --platform wsl \
  --passes 2 \
  --current-pass 2 >/dev/null
grep -Fq 'E2E result: PASS' "$ARTIFACT_DIR/e2e-report.txt"
grep -Fq '<testsuite name="dotfiles-e2e" tests="1" failures="0"' \
  "$ARTIFACT_DIR/e2e-results.xml"

printf 'E2E report test passed\n'
