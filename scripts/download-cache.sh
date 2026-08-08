#!/usr/bin/env bash
# Inspect or prune the checksum-keyed verified download cache.

set -euo pipefail

DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/download-cache.sh <command> [args]

  status           Show cache path, object count, and disk usage
  prune [days]     Remove entries unused for more than 30 days (or DAYS)
EOF
}

root="$(download_cache_root)"
objects="$root/sha256"

case "${1:-status}" in
  status)
    count=0
    bytes=0
    if [[ -d "$objects" ]]; then
      count="$(find "$objects" -maxdepth 1 -type f | wc -l | tr -d ' ')"
      bytes="$(du -sb "$objects" | awk '{print $1}')"
    fi
    printf 'Cache: %s\nObjects: %s\nBytes: %s\n' "$root" "$count" "$bytes"
    ;;
  prune)
    days="${2:-30}"
    [[ "$days" =~ ^[0-9]+$ ]] || {
      printf 'download-cache: DAYS must be a non-negative integer\n' >&2
      exit 2
    }
    removed=0
    if [[ -d "$objects" ]]; then
      while IFS= read -r -d '' entry; do
        rm -f -- "$entry"
        removed=$((removed + 1))
      done < <(find "$objects" -maxdepth 1 -type f -mtime "+$days" -print0)
    fi
    if [[ -d "$root/locks" ]]; then
      find "$root/locks" -maxdepth 1 -type f -mtime "+$days" -delete
    fi
    printf 'Pruned %s verified download cache object(s) older than %s day(s)\n' \
      "$removed" "$days"
    ;;
  -h | --help)
    usage
    ;;
  *)
    printf 'download-cache: unknown command: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
