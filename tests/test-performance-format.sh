#!/usr/bin/env bash
# Verify the shared duration formatter stays consistent across Bash and jq.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=../scripts/performance-format.sh
source "$DOTFILES_DIR/scripts/performance-format.sh"

[[ "$(format_duration_ms 87)" == '87 ms (0.087 s)' ]]
[[ "$(format_duration_ms 1234)" == '1.234 s (1234 ms)' ]]
[[ "$(format_duration_ms 65000)" == '1m 05.000s (65.000 s / 65000 ms)' ]]
[[ "$(duration_ms_to_seconds 1234)" == '1.234' ]]
[[ "$(duration_seconds_to_ms 1.234)" == '1234' ]]
[[ "$(duration_ms_to_seconds null)" == 'null' ]]
[[ "$(format_duration_ms null)" == 'n/a' ]]

jq -L "$DOTFILES_DIR/scripts" -n '
  include "performance-format";
  [
    (87 | duration_human),
    (1234 | duration_human),
    (65000 | duration_human),
    (1234 | duration_seconds)
  ] == [
    "87 ms (0.087 s)",
    "1.234 s (1234 ms)",
    "1m 05.000s (65.000 s / 65000 ms)",
    1.234
  ]
' >/dev/null

printf 'Performance formatter test passed\n'
