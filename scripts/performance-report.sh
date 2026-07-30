#!/usr/bin/env bash
# Measure interactive tooling and report non-blocking performance budget regressions.

set -euo pipefail

ARTIFACT_DIR="${1:-/tmp/dotfiles-performance}"
ZSH_RESULT="$ARTIFACT_DIR/zsh-startup.json"
INSTALL_TIMINGS="$ARTIFACT_DIR/install-timings.tsv"
JSON_REPORT="$ARTIFACT_DIR/performance.json"
MARKDOWN_REPORT="$ARTIFACT_DIR/performance.md"
ZSH_BUDGET_MS="${DOTFILES_ZSH_REPORT_BUDGET_MS:-1000}"
STARSHIP_BUDGET_MS="${DOTFILES_STARSHIP_BUDGET_MS:-250}"
SECOND_PASS_BUDGET_MS="${DOTFILES_SECOND_PASS_BUDGET_MS:-180000}"
ENFORCE="${DOTFILES_PERFORMANCE_ENFORCE:-0}"

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

second_pass_ms="null"
if [[ -r "$INSTALL_TIMINGS" ]]; then
  value="$(awk -F '\t' '$1 == 2 { value = $2 } END { print value }' "$INSTALL_TIMINGS")"
  [[ "$value" =~ ^[0-9]+$ ]] && second_pass_ms="$value"
fi

zsh_status="$(metric_status "$zsh_ms" "$ZSH_BUDGET_MS")"
starship_status="$(metric_status "$starship_ms" "$STARSHIP_BUDGET_MS")"
second_pass_status="$(metric_status "$second_pass_ms" "$SECOND_PASS_BUDGET_MS")"

jq -n \
  --argjson zsh_value "$zsh_ms" \
  --argjson zsh_budget "$ZSH_BUDGET_MS" \
  --arg zsh_status "$zsh_status" \
  --argjson starship_value "$starship_ms" \
  --argjson starship_budget "$STARSHIP_BUDGET_MS" \
  --arg starship_status "$starship_status" \
  --argjson second_value "$second_pass_ms" \
  --argjson second_budget "$SECOND_PASS_BUDGET_MS" \
  --arg second_status "$second_pass_status" \
  '{
    report_only: true,
    metrics: {
      zsh_startup: {
        value_ms: $zsh_value,
        budget_ms: $zsh_budget,
        status: $zsh_status
      },
      starship_render: {
        value_ms: $starship_value,
        budget_ms: $starship_budget,
        status: $starship_status
      },
      second_install_pass: {
        value_ms: $second_value,
        budget_ms: $second_budget,
        status: $second_status
      }
    }
  }' >"$JSON_REPORT"

display_value() {
  [[ "$1" == null ]] && printf 'n/a' || printf '%s ms' "$1"
}

{
  printf '## Dotfiles performance budgets\n\n'
  printf 'These budgets are report-only and do not block merges.\n\n'
  printf '| Metric | Observed | Budget | Status |\n'
  printf '|---|---:|---:|---|\n'
  printf '| Zsh startup | %s | %s ms | %s |\n' \
    "$(display_value "$zsh_ms")" "$ZSH_BUDGET_MS" "$zsh_status"
  printf '| Starship render | %s | %s ms | %s |\n' \
    "$(display_value "$starship_ms")" "$STARSHIP_BUDGET_MS" "$starship_status"
  printf '| Second install pass | %s | %s ms | %s |\n' \
    "$(display_value "$second_pass_ms")" "$SECOND_PASS_BUDGET_MS" "$second_pass_status"
} >"$MARKDOWN_REPORT"

chmod 644 "$JSON_REPORT" "$MARKDOWN_REPORT"
cat "$MARKDOWN_REPORT"

if [[ "$ENFORCE" == 1 ]] &&
  [[ "$zsh_status" == regression ||
    "$starship_status" == regression ||
    "$second_pass_status" == regression ]]; then
  exit 1
fi
