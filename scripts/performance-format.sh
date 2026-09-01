#!/usr/bin/env bash
# Shared duration formatting for performance artifacts and bootstrap summaries.

format_duration_ms() {
  local value="${1:-}"
  if [[ "$value" == null || -z "$value" || ! "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    printf 'n/a\n'
    return 0
  fi

  LC_ALL=C awk -v raw="$value" '
    BEGIN {
      sign = raw < 0 ? "-" : ""
      absolute = raw < 0 ? -raw : raw
      rounded = int(absolute + 0.5)
      minutes = int(rounded / 60000)
      remaining = rounded - (minutes * 60000)
      seconds = int(remaining / 1000)
      milliseconds = remaining - (seconds * 1000)
      whole_seconds = int(rounded / 1000)
      if (minutes > 0) {
        printf "%s%dm %02d.%03ds (%s%d.%03d s / %s%d ms)\n", \
          sign, minutes, seconds, milliseconds, sign, whole_seconds, \
          rounded % 1000, sign, rounded
      } else if (rounded >= 1000) {
        printf "%s%d.%03d s (%s%d ms)\n", sign, whole_seconds, \
          rounded % 1000, sign, rounded
      } else {
        printf "%s%d ms (%s0.%03d s)\n", sign, rounded, sign, rounded
      }
    }
  '
}

duration_ms_to_seconds() {
  local value="${1:-}"
  if [[ "$value" == null || -z "$value" || ! "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    printf 'null\n'
    return 0
  fi
  LC_ALL=C awk -v raw="$value" 'BEGIN { printf "%.3f\n", raw / 1000 }'
}

duration_seconds_to_ms() {
  local value="${1:-}"
  if [[ "$value" == null || -z "$value" || ! "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    printf 'null\n'
    return 0
  fi
  LC_ALL=C awk -v raw="$value" 'BEGIN { printf "%.0f\n", raw * 1000 }'
}
