#!/usr/bin/env bash
# Measure interactive tooling and report non-blocking performance budget regressions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=performance-format.sh
source "$SCRIPT_DIR/performance-format.sh"

ARTIFACT_DIR="${1:-/tmp/dotfiles-performance}"
ZSH_RESULT="$ARTIFACT_DIR/zsh-startup.json"
INSTALL_TIMINGS="$ARTIFACT_DIR/install-timings.tsv"
JSON_REPORT="$ARTIFACT_DIR/performance.json"
MARKDOWN_REPORT="$ARTIFACT_DIR/performance.md"
ZSH_BUDGET_MS="${DOTFILES_ZSH_REPORT_BUDGET_MS:-1000}"
STARSHIP_BUDGET_MS="${DOTFILES_STARSHIP_BUDGET_MS:-250}"
FIRST_PASS_BUDGET_MS="${DOTFILES_FIRST_PASS_BUDGET_MS:-600000}"
SECOND_PASS_BUDGET_MS="${DOTFILES_SECOND_PASS_BUDGET_MS:-180000}"
FULL_INSTALL_BUDGET_MS="${DOTFILES_FULL_INSTALL_BUDGET_MS:-900000}"
ENFORCE="${DOTFILES_PERFORMANCE_ENFORCE:-0}"
PROFILE="${E2E_PROFILE:-${DOTFILES_PERFORMANCE_PROFILE:-unknown}}"
if [[ -n "${DOTFILES_PERFORMANCE_PLATFORM:-}" ]]; then
  PLATFORM="$DOTFILES_PERFORMANCE_PLATFORM"
elif [[ "${DOTFILES_WSL:-false}" == true ]]; then
  PLATFORM=wsl-simulated
else
  PLATFORM=native
fi
RUN_ID="${GITHUB_RUN_ID:-local}"
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
COMMIT="${GITHUB_SHA:-local}"
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

mkdir -p "$ARTIFACT_DIR"

metric_status() {
  local value="$1" budget="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf 'unavailable\n'
  elif ((value > budget)); then
    printf 'regression\n'
  else
    printf 'pass\n'
  fi
}

install_timing_ms() {
  local wanted_pass="$1" value=""
  [[ -r "$INSTALL_TIMINGS" ]] || {
    printf 'null\n'
    return 0
  }
  value="$(awk -F '\t' -v wanted="$wanted_pass" \
    '$1 == wanted && $2 ~ /^[0-9]+([.][0-9]+)?$/ { value = $2 } END { print value }' \
    "$INSTALL_TIMINGS")"
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && printf '%s\n' "$value" || printf 'null\n'
}

zsh_ms="null"
if [[ -r "$ZSH_RESULT" ]]; then
  value="$(jq -r '.median_ms // empty' "$ZSH_RESULT" 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+$ ]] && zsh_ms="$value"
fi

starship_ms="null"
if command -v starship >/dev/null 2>&1; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  starship prompt --path "$PWD" --status 0 --cmd-duration 0 >/dev/null
  for _ in 1 2 3 4 5; do
    started="$(date +%s%N)"
    starship prompt --path "$PWD" --status 0 --cmd-duration 0 >/dev/null
    ended="$(date +%s%N)"
    printf '%s\n' "$(((ended - started) / 1000000))" >>"$tmp"
  done
  starship_ms="$(sort -n "$tmp" | sed -n '3p')"
fi

first_pass_ms="$(install_timing_ms 1)"
second_pass_ms="$(install_timing_ms 2)"
full_install_ms="null"
[[ "$PROFILE" == full ]] && full_install_ms="$first_pass_ms"

zsh_status="$(metric_status "$zsh_ms" "$ZSH_BUDGET_MS")"
starship_status="$(metric_status "$starship_ms" "$STARSHIP_BUDGET_MS")"
first_pass_status="$(metric_status "$first_pass_ms" "$FIRST_PASS_BUDGET_MS")"
second_pass_status="$(metric_status "$second_pass_ms" "$SECOND_PASS_BUDGET_MS")"
full_install_status="$(metric_status "$full_install_ms" "$FULL_INSTALL_BUDGET_MS")"

zsh_seconds="$(duration_ms_to_seconds "$zsh_ms")"
starship_seconds="$(duration_ms_to_seconds "$starship_ms")"
first_pass_seconds="$(duration_ms_to_seconds "$first_pass_ms")"
second_pass_seconds="$(duration_ms_to_seconds "$second_pass_ms")"
full_install_seconds="$(duration_ms_to_seconds "$full_install_ms")"
zsh_human="$(format_duration_ms "$zsh_ms")"
starship_human="$(format_duration_ms "$starship_ms")"
first_pass_human="$(format_duration_ms "$first_pass_ms")"
second_pass_human="$(format_duration_ms "$second_pass_ms")"
full_install_human="$(format_duration_ms "$full_install_ms")"
zsh_budget_human="$(format_duration_ms "$ZSH_BUDGET_MS")"
starship_budget_human="$(format_duration_ms "$STARSHIP_BUDGET_MS")"
first_pass_budget_human="$(format_duration_ms "$FIRST_PASS_BUDGET_MS")"
second_pass_budget_human="$(format_duration_ms "$SECOND_PASS_BUDGET_MS")"
full_install_budget_human="$(format_duration_ms "$FULL_INSTALL_BUDGET_MS")"

jq -L "$SCRIPT_DIR" -n \
  --arg generated_at "$GENERATED_AT" \
  --arg profile "$PROFILE" \
  --arg platform "$PLATFORM" \
  --arg run_id "$RUN_ID" \
  --arg run_attempt "$RUN_ATTEMPT" \
  --arg commit "$COMMIT" \
  --argjson zsh_value "$zsh_ms" \
  --argjson zsh_seconds "$zsh_seconds" \
  --arg zsh_human "$zsh_human" \
  --argjson zsh_budget "$ZSH_BUDGET_MS" \
  --argjson zsh_budget_seconds "$(duration_ms_to_seconds "$ZSH_BUDGET_MS")" \
  --arg zsh_budget_human "$zsh_budget_human" \
  --arg zsh_status "$zsh_status" \
  --argjson starship_value "$starship_ms" \
  --argjson starship_seconds "$starship_seconds" \
  --arg starship_human "$starship_human" \
  --argjson starship_budget "$STARSHIP_BUDGET_MS" \
  --argjson starship_budget_seconds "$(duration_ms_to_seconds "$STARSHIP_BUDGET_MS")" \
  --arg starship_budget_human "$starship_budget_human" \
  --arg starship_status "$starship_status" \
  --argjson first_value "$first_pass_ms" \
  --argjson first_seconds "$first_pass_seconds" \
  --arg first_human "$first_pass_human" \
  --argjson first_budget "$FIRST_PASS_BUDGET_MS" \
  --argjson first_budget_seconds "$(duration_ms_to_seconds "$FIRST_PASS_BUDGET_MS")" \
  --arg first_budget_human "$first_pass_budget_human" \
  --arg first_status "$first_pass_status" \
  --argjson second_value "$second_pass_ms" \
  --argjson second_seconds "$second_pass_seconds" \
  --arg second_human "$second_pass_human" \
  --argjson second_budget "$SECOND_PASS_BUDGET_MS" \
  --argjson second_budget_seconds "$(duration_ms_to_seconds "$SECOND_PASS_BUDGET_MS")" \
  --arg second_budget_human "$second_pass_budget_human" \
  --arg second_status "$second_pass_status" \
  --argjson full_value "$full_install_ms" \
  --argjson full_seconds "$full_install_seconds" \
  --arg full_human "$full_install_human" \
  --argjson full_budget "$FULL_INSTALL_BUDGET_MS" \
  --argjson full_budget_seconds "$(duration_ms_to_seconds "$FULL_INSTALL_BUDGET_MS")" \
  --arg full_budget_human "$full_install_budget_human" \
  --arg full_status "$full_install_status" \
  '{
    schema_version: 2,
    generated_at: $generated_at,
    context: {
      profile: $profile,
      platform: $platform,
      run_id: $run_id,
      run_attempt: $run_attempt,
      commit: $commit
    },
    report_only: true,
    metrics: {
      zsh_startup: {
        value_ms: $zsh_value,
        value_seconds: $zsh_seconds,
        value_human: $zsh_human,
        budget_ms: $zsh_budget,
        budget_seconds: $zsh_budget_seconds,
        budget_human: $zsh_budget_human,
        status: $zsh_status
      },
      starship_render: {
        value_ms: $starship_value,
        value_seconds: $starship_seconds,
        value_human: $starship_human,
        budget_ms: $starship_budget,
        budget_seconds: $starship_budget_seconds,
        budget_human: $starship_budget_human,
        status: $starship_status
      },
      first_install_pass: {
        value_ms: $first_value,
        value_seconds: $first_seconds,
        value_human: $first_human,
        budget_ms: $first_budget,
        budget_seconds: $first_budget_seconds,
        budget_human: $first_budget_human,
        status: $first_status
      },
      second_install_pass: {
        value_ms: $second_value,
        value_seconds: $second_seconds,
        value_human: $second_human,
        budget_ms: $second_budget,
        budget_seconds: $second_budget_seconds,
        budget_human: $second_budget_human,
        status: $second_status
      },
      full_install: {
        value_ms: $full_value,
        value_seconds: $full_seconds,
        value_human: $full_human,
        budget_ms: $full_budget,
        budget_seconds: $full_budget_seconds,
        budget_human: $full_budget_human,
        status: $full_status
      }
    }
  }' >"$JSON_REPORT"

{
  printf '## Dotfiles performance budgets\n\n'
  printf 'Profile: `%s` | Platform: `%s` | Run: `%s`\n\n' "$PROFILE" "$PLATFORM" "$RUN_ID"
  printf 'These budgets are report-only and do not block merges.\n\n'
  printf '| Metric | Observed | Budget | Status |\n'
  printf '|---|---:|---:|---|\n'
  printf '| Zsh startup | %s | %s | %s |\n' \
    "$zsh_human" "$zsh_budget_human" "$zsh_status"
  printf '| Starship render | %s | %s | %s |\n' \
    "$starship_human" "$starship_budget_human" "$starship_status"
  printf '| First install pass | %s | %s | %s |\n' \
    "$first_pass_human" "$first_pass_budget_human" "$first_pass_status"
  printf '| Second install pass | %s | %s | %s |\n' \
    "$second_pass_human" "$second_pass_budget_human" "$second_pass_status"
  if [[ "$PROFILE" == full ]]; then
    printf '| Full install (pass 1) | %s | %s | %s |\n' \
      "$full_install_human" "$full_install_budget_human" "$full_install_status"
  fi
} >"$MARKDOWN_REPORT"

chmod 644 "$JSON_REPORT" "$MARKDOWN_REPORT"
cat "$MARKDOWN_REPORT"

if [[ "$ENFORCE" == 1 ]] &&
  [[ "$zsh_status" == regression ||
    "$starship_status" == regression ||
    "$first_pass_status" == regression ||
    "$second_pass_status" == regression ||
    "$full_install_status" == regression ]]; then
  exit 1
fi
