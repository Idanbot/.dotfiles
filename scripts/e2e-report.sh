#!/usr/bin/env bash
# Produce concise human and JUnit reports from an E2E bootstrap run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=performance-format.sh
source "$SCRIPT_DIR/performance-format.sh"

ARTIFACT_DIR=""
STATE_DIR=""
STATUS=""
PROFILE=""
PLATFORM=""
PASSES=""
CURRENT_PASS=""

usage() {
  cat <<'EOF'
Usage: scripts/e2e-report.sh --artifacts DIR --state DIR --status CODE [options]

Options:
  --profile NAME
  --platform NAME
  --passes COUNT
  --current-pass COUNT
EOF
}

while (($#)); do
  case "$1" in
    --artifacts)
      ARTIFACT_DIR="${2:-}"
      shift 2
      ;;
    --state)
      STATE_DIR="${2:-}"
      shift 2
      ;;
    --status)
      STATUS="${2:-}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --platform)
      PLATFORM="${2:-}"
      shift 2
      ;;
    --passes)
      PASSES="${2:-}"
      shift 2
      ;;
    --current-pass)
      CURRENT_PASS="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

[[ -n "$ARTIFACT_DIR" && -n "$STATE_DIR" && "$STATUS" =~ ^[0-9]+$ ]] || {
  usage >&2
  exit 2
}

mkdir -p "$ARTIFACT_DIR"
REPORT="$ARTIFACT_DIR/e2e-report.txt"
JUNIT="$ARTIFACT_DIR/e2e-results.xml"
latest_event=""
latest_summary=""
failed_stage="unknown"
failure_message="E2E command exited with status $STATUS"
run_id=""

if [[ -d "$STATE_DIR/logs" ]]; then
  latest_event="$(
    find "$STATE_DIR/logs" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@ %p\n' |
      sort -nr | head -n 1 | cut -d' ' -f2-
  )"
fi
if [[ -d "$STATE_DIR/runs" ]]; then
  latest_summary="$(
    find "$STATE_DIR/runs" -type f -name summary.json -printf '%T@ %p\n' |
      sort -nr | head -n 1 | cut -d' ' -f2-
  )"
fi

if [[ -n "$latest_event" && -s "$latest_event" ]]; then
  error_events="$(
    jq -sc '
      map(select(.level == "error"))
    ' "$latest_event" 2>/dev/null || printf '[]'
  )"
  failed_stage="$(
    jq -r 'last | .stage // .section // "unknown"' <<<"$error_events"
  )"
  failure_message="$(
    jq -r '
      ([.[] | select((.message // "") | startswith("failed line=") | not)] |
        last | .message) //
      (last | .message) //
      empty
    ' <<<"$error_events"
  )"
  [[ -n "$failure_message" ]] ||
    failure_message="E2E command exited with status $STATUS"
  run_id="$(jq -sr 'last | .run_id // empty' "$latest_event" 2>/dev/null || true)"
fi

command_text="/dotfiles/scripts/install.sh --source /dotfiles --profile ${PROFILE:-unknown} --conflict-policy backup --yes"
remedy="Inspect $ARTIFACT_DIR/bootstrap-pass-${CURRENT_PASS:-unknown}.log"
if [[ -n "$run_id" ]]; then
  remedy="/dotfiles/scripts/install.sh --resume=$run_id"
fi

{
  printf 'E2E result: %s\n' "$([[ "$STATUS" -eq 0 ]] && printf PASS || printf FAIL)"
  printf 'Profile: %s\n' "${PROFILE:-unknown}"
  printf 'Platform: %s\n' "${PLATFORM:-unknown}"
  printf 'Pass: %s/%s\n' "${CURRENT_PASS:-unknown}" "${PASSES:-unknown}"
  printf 'Exit: %s\n' "$STATUS"
  printf 'Stage: %s\n' "$([[ "$STATUS" -eq 0 ]] && printf complete || printf '%s' "$failed_stage")"
  printf 'Command: %s\n' "$command_text"
  if [[ "$STATUS" -ne 0 ]]; then
    printf 'Cause: %s\n' "$failure_message"
    printf 'Remedy: %s\n' "$remedy"
    log="$ARTIFACT_DIR/bootstrap-pass-${CURRENT_PASS:-}.log"
    if [[ -f "$log" ]]; then
      printf '\nLast 40 log lines (redacted):\n'
      tail -n 40 "$log" |
        sed -E \
          -e $'s/\033\\[[0-9;]*[[:alpha:]]//g' \
          -e 's/((token|password|secret|api[_-]?key)[=:][[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig'
    fi
  fi
} >"$REPORT"

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

duration=0
if [[ -n "$latest_summary" ]]; then
  duration="$(jq -r '.duration_seconds // 0' "$latest_summary" 2>/dev/null || printf 0)"
fi
summary_duration_ms="$(
  if [[ -n "$latest_summary" ]]; then
    jq -r '
      if (.duration_ms | type) == "number" then .duration_ms
      elif (.duration_seconds | type) == "number" then (.duration_seconds * 1000 | round)
      else empty
      end
    ' "$latest_summary" 2>/dev/null || true
  fi
)"
if [[ ! "$summary_duration_ms" =~ ^[0-9]+$ ]]; then
  summary_duration_ms=""
fi

{
  if [[ -n "$summary_duration_ms" ]]; then
    printf '\nInstaller run duration: %s\n' "$(format_duration_ms "$summary_duration_ms")"
  fi
  if [[ -r "$ARTIFACT_DIR/install-timings.tsv" ]]; then
    printf '\nInstallation timings:\n'
    while IFS=$'\t' read -r phase elapsed_ms _; do
      [[ "$elapsed_ms" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
      case "$phase" in
        1)
          if [[ "$PROFILE" == full ]]; then
            label='Full install (pass 1)'
          else
            label='Install pass 1'
          fi
          ;;
        2) label='Install pass 2' ;;
        reapply) label='Restore reapply' ;;
        *) label="Install $phase" ;;
      esac
      printf '  %s: %s\n' "$label" "$(format_duration_ms "$elapsed_ms")"
    done <"$ARTIFACT_DIR/install-timings.tsv"
  fi
} >>"$REPORT"

{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<testsuite name="dotfiles-e2e" tests="1" failures="%s" time="%s">\n' \
    "$([[ "$STATUS" -eq 0 ]] && printf 0 || printf 1)" "$duration"
  printf '  <testcase classname="bootstrap.%s" name="%s-%s" time="%s">' \
    "$(printf '%s' "${PROFILE:-unknown}" | xml_escape)" \
    "$(printf '%s' "${PLATFORM:-unknown}" | xml_escape)" \
    "$(printf '%s' "${PROFILE:-unknown}" | xml_escape)" "$duration"
  if [[ "$STATUS" -ne 0 ]]; then
    printf '\n    <failure message="%s">' \
      "$(printf '%s' "$failure_message" | xml_escape)"
    xml_escape <"$REPORT"
    printf '</failure>\n  '
  fi
  printf '</testcase>\n</testsuite>\n'
} >"$JUNIT"

chmod 644 "$REPORT" "$JUNIT"
cat "$REPORT"
