#!/usr/bin/env bash
# Apply only the selected section's external trees, retaining chezmoi conflicts.
set -euo pipefail
ROOT="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=scripts/chezmoi-network.sh
source "$ROOT/scripts/chezmoi-network.sh"
paths="$(/usr/bin/python3 "$ROOT/scripts/section-state.py" --source "$ROOT" externals "${1:?section required}")"
[[ -n "$paths" ]] || exit 0
targets=()
while IFS= read -r path; do
  [[ "$path" != /* && "$path" != *..* ]] || exit 1
  targets+=("$HOME/$path")
done <<<"$paths"
chezmoi_with_retry status --source="$ROOT" --exclude=scripts --recursive -- "${targets[@]}" >/dev/null
chezmoi apply --source="$ROOT" --exclude=scripts --recursive -- "${targets[@]}"
# A skipped conflict must not advance the section fingerprint.
chezmoi verify --source="$ROOT" --exclude=scripts --recursive -- "${targets[@]}"
