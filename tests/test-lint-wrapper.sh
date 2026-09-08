#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/repo/"{scripts,tests,dot_local/bin}
touch "$temporary/repo/scripts/example.sh" "$temporary/repo/dot_local/bin/executable_demo"
for tool in shellcheck shfmt yamllint; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "${0##*/}" "$*" >> "$CALLS"\n[ "${0##*/}" != "$FAIL_TOOL" ]\n' >"$temporary/bin/$tool"
  chmod +x "$temporary/bin/$tool"
done
export CALLS="$temporary/calls"
for tool in shellcheck shfmt yamllint; do
  if PATH="$temporary/bin:$PATH" FAIL_TOOL="$tool" bash "$ROOT/tests/test-lint.sh" "$temporary/repo" >"$temporary/output" 2>&1; then
    printf 'Ignored %s failure\n' "$tool" >&2
    exit 1
  fi
  grep -Fq "[FAIL] $tool" "$temporary/output"
done
PATH="$temporary/bin:$PATH" FAIL_TOOL=none bash "$ROOT/tests/test-lint.sh" "$temporary/repo"
grep -Fq 'dot_local/bin/executable_demo' "$CALLS"
grep -Fq 'SC1090,SC1091' "$CALLS"
! grep -Fq relaxed "$CALLS"
printf 'Lint wrapper regression tests passed\n'
