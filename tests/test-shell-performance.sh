#!/usr/bin/env bash
# Enforce a warm interactive zsh startup budget after a real bootstrap.

set -euo pipefail

BUDGET_MS="${DOTFILES_ZSH_STARTUP_BUDGET_MS:-3000}"
ARTIFACT="${1:-/tmp/zsh-startup.json}"
DEBUG_DIR="${ARTIFACT%.json}-debug"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

command -v zsh >/dev/null 2>&1 || {
  printf 'zsh is unavailable\n' >&2
  exit 1
}
command -v script >/dev/null 2>&1 || {
  printf 'script(1) is unavailable for pseudo-terminal startup testing\n' >&2
  exit 1
}

run_zsh() {
  local transcript="$1"
  local status=0
  TERM=xterm-256color timeout 10 script -qefc 'zsh -lic exit' "$transcript" </dev/null >/dev/null || status=$?
  if [[ "$status" -ne 0 ]]; then
    rm -rf "$DEBUG_DIR"
    mkdir -p "$DEBUG_DIR"
    cp -a "$tmp"/. "$DEBUG_DIR/"
    ps -ef >"$DEBUG_DIR/processes.txt"
    printf 'zsh startup command failed with exit %s; diagnostics: %s\n' "$status" "$DEBUG_DIR" >&2
    return "$status"
  fi
}

run_zsh "$tmp/warmup.out"
: >"$tmp/times"
for run in 1 2 3; do
  started="$(date +%s%N)"
  run_zsh "$tmp/run-$run.out"
  ended="$(date +%s%N)"
  printf '%s\n' "$(((ended - started) / 1000000))" >>"$tmp/times"
done

median="$(sort -n "$tmp/times" | sed -n '2p')"
mkdir -p "$(dirname "$ARTIFACT")"
printf '{"budget_ms":%s,"median_ms":%s,"runs_ms":[%s]}\n' \
  "$BUDGET_MS" "$median" "$(paste -sd, "$tmp/times")" >"$ARTIFACT"

if grep -Eaiq \
  'command not found|no such file or directory|can.t change option|plugin: .*not found|compinit:|(^|[^a-z])error:' \
  "$tmp"/*.out; then
  cat "$tmp"/*.out >&2
  printf 'zsh startup transcript contains errors\n' >&2
  exit 1
fi
if [[ "$median" -gt "$BUDGET_MS" ]]; then
  printf 'zsh startup median %sms exceeded %sms budget\n' "$median" "$BUDGET_MS" >&2
  exit 1
fi
printf 'zsh startup median: %sms (budget %sms)\n' "$median" "$BUDGET_MS"
