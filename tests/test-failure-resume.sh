#!/usr/bin/env bash
# Inject a stage failure and prove checkpoint-based resume skips completed work.

set -euo pipefail

DOTFILES_DIR="${1:-/dotfiles}"
ARTIFACT_ROOT="${DOTFILES_ARTIFACT_DIR:-/artifacts}"
ARTIFACT_DIR="$ARTIFACT_ROOT/failure-resume"
if ! mkdir -p "$ARTIFACT_DIR" 2>/dev/null; then
  ARTIFACT_ROOT="${TMPDIR:-/tmp}/dotfiles-artifacts"
  ARTIFACT_DIR="$ARTIFACT_ROOT/failure-resume"
  mkdir -p "$ARTIFACT_DIR"
fi

set +e
DOTFILES_FAIL_AT=source:after \
  DOTFILES_LOG_FILE="$ARTIFACT_DIR/failed.log" \
  "$DOTFILES_DIR/scripts/install.sh" \
  --source "$DOTFILES_DIR" --profile minimal --yes --no-doctor \
  >"$ARTIFACT_DIR/failed-console.log" 2>&1
status=$?
set -e
[[ "$status" -eq 98 ]] || {
  printf 'Expected injected exit 98, got %s\n' "$status" >&2
  exit 1
}

run_id="$(<"$HOME/.local/state/dotfiles/runs/latest")"
[[ -f "$HOME/.local/state/dotfiles/runs/$run_id/checkpoints/prerequisites.done" ]]
[[ -f "$HOME/.local/state/dotfiles/runs/$run_id/checkpoints/source.done" ]]
[[ ! -f "$HOME/.local/state/dotfiles/runs/$run_id/checkpoints/apply.done" ]]

DOTFILES_LOG_FILE="$ARTIFACT_DIR/resumed.log" \
  "$DOTFILES_DIR/scripts/install.sh" --resume="$run_id" --no-doctor \
  >"$ARTIFACT_DIR/resumed-console.log" 2>&1

grep -Fq 'prerequisites already completed' "$ARTIFACT_DIR/resumed-console.log"
grep -Fq 'source already completed' "$ARTIFACT_DIR/resumed-console.log"
jq -e '.status == "success"' "$HOME/.local/state/dotfiles/runs/$run_id/summary.json" >/dev/null
[[ ! -f "$HOME/.local/state/dotfiles/runs/latest" ]]
cp "$HOME/.local/state/dotfiles/runs/$run_id/summary.json" "$ARTIFACT_DIR/summary.json"
cp -a "$HOME/.local/state/dotfiles/runs/$run_id/checkpoints" "$ARTIFACT_DIR/checkpoints"
chmod -R u=rwX,go=rX "$ARTIFACT_DIR"

printf 'Failure/resume test passed: %s\n' "$run_id"
