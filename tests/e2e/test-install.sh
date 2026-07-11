#!/usr/bin/env bash
# Execute the same installer path used by the public one-liner and retain rich diagnostics.

set -Eeuo pipefail

PROFILE="${E2E_PROFILE:-base}"
PASSES="${E2E_PASSES:-2}"
ARTIFACT_DIR="/artifacts/${PROFILE}-${DOTFILES_WSL:-false}"
STATE_DIR="$HOME/.local/state/dotfiles"
mkdir -p "$ARTIFACT_DIR"
mkdir -p "$HOME/.config/dotfiles"
printf 'history-sentinel\n' >"$HOME/.zsh_history"
printf '# e2e-local-sentinel\n' >"$HOME/.config/dotfiles/local.zsh"
chmod 600 "$HOME/.zsh_history" "$HOME/.config/dotfiles/local.zsh"

collect_observability() {
  mkdir -p "$ARTIFACT_DIR/state"
  [[ ! -d "$STATE_DIR/logs" ]] || cp -a "$STATE_DIR/logs" "$ARTIFACT_DIR/state/"
  [[ ! -d "$STATE_DIR/runs" ]] || cp -a "$STATE_DIR/runs" "$ARTIFACT_DIR/state/"
  [[ ! -f "$STATE_DIR/installed.tsv" ]] || cp "$STATE_DIR/installed.tsv" "$ARTIFACT_DIR/state/"
}

collect_diagnostics() {
  local status="$1"
  {
    printf 'exit=%s\nprofile=%s\nwsl=%s\n' "$status" "$PROFILE" "${DOTFILES_WSL:-auto}"
    printf '\nDisk:\n'
    df -h
    printf '\nMemory:\n'
    free -h || true
    printf '\nProcesses:\n'
    ps aux || true
    printf '\nAPT sources:\n'
    find /etc/apt -maxdepth 2 -type f -print -exec sed -n '1,80p' {} \; 2>/dev/null || true
    printf '\nHome files:\n'
    find "$HOME" -maxdepth 4 -printf '%M %u:%g %p\n' 2>/dev/null | sort || true
    printf '\nRun summaries:\n'
    find "$STATE_DIR/runs" -name summary.json -exec sh -c 'echo ===$1===; cat "$1"' _ {} \; 2>/dev/null || true
  } >"$ARTIFACT_DIR/diagnostics.txt"
  collect_observability
  # CI artifacts contain only synthetic test-home data and must be readable by
  # the host runner even when the container and runner use different UIDs.
  chmod -R u=rwX,go=rX "$ARTIFACT_DIR"
}
trap 'status=$?; collect_diagnostics "$status"; exit "$status"' EXIT

printf 'profile=%s\nwsl=%s\npasses=%s\n' "$PROFILE" "${DOTFILES_WSL:-auto}" "$PASSES" >"$ARTIFACT_DIR/context.txt"
env | sed -E 's/((TOKEN|PASSWORD|SECRET|KEY)=).*/\1[REDACTED]/I' | sort >"$ARTIFACT_DIR/environment.txt"

for pass in $(seq 1 "$PASSES"); do
  printf '\n===== E2E %s pass %s/%s =====\n' "$PROFILE" "$pass" "$PASSES"
  DOTFILES_LOG_FILE="$ARTIFACT_DIR/bootstrap-pass-${pass}.log" \
    /dotfiles/scripts/install.sh \
    --source /dotfiles \
    --profile "$PROFILE" \
    --conflict-policy backup \
    --yes
  jq empty "$STATE_DIR/runs"/*/summary.json
done

latest_summary="$(find "$STATE_DIR/runs" -name summary.json -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
jq -e '.status == "success" and .duration_seconds >= 0' "$latest_summary" >/dev/null

ledger="$STATE_DIR/installed.tsv"
[[ -f "$ledger" ]] || {
  printf 'Managed-install ledger is missing\n' >&2
  exit 1
}
[[ "$(stat -c '%a' "$ledger")" == 600 ]] || {
  printf 'Ledger mode is not 600\n' >&2
  exit 1
}

for leaked_metadata in "$HOME/artifacts" "$HOME/docs"; do
  [[ ! -e "$leaked_metadata" ]] || {
    printf 'Repository metadata leaked into the target home: %s\n' "$leaked_metadata" >&2
    exit 1
  }
done

grep -Fxq 'history-sentinel' "$HOME/.zsh_history"
grep -Fxq '# e2e-local-sentinel' "$HOME/.config/dotfiles/local.zsh"
[[ "$(stat -c '%a' "$HOME/.config/dotfiles/local.zsh")" == 600 ]]

if [[ "${DOTFILES_WSL:-false}" == true ]]; then
  [[ ! -e "$HOME/.config/kitty" ]] || {
    printf 'Native-only Kitty config was applied in WSL mode\n' >&2
    exit 1
  }
else
  [[ -f "$HOME/.config/kitty/kitty.conf" ]]
fi

for log in "$ARTIFACT_DIR"/bootstrap-pass-*.log; do
  [[ "$(stat -c '%a' "$log")" == 600 ]] || {
    printf 'Log mode is not 600: %s\n' "$log" >&2
    exit 1
  }
  if LC_ALL=C grep -q $'\033' "$log"; then
    printf 'Persisted log contains ANSI escapes: %s\n' "$log" >&2
    exit 1
  fi
done

/dotfiles/tests/test-shell-performance.sh "$ARTIFACT_DIR/zsh-startup.json"

find "$STATE_DIR/logs" -name '*.jsonl' -exec sh -c 'while IFS= read -r line; do printf "%s" "$line" | jq -e . >/dev/null; done < "$1"' _ {} \;
collect_diagnostics 0
trap - EXIT
printf 'E2E profile %s passed (%s installation pass(es))\n' "$PROFILE" "$PASSES"
