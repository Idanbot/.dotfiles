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
verification="$root/verification"

prune_entry() (
  local entry="$1" lock="$2" days="$3" cache_fd expired
  shift 3
  # Lock pathnames are permanent: unlinking one permits concurrent lock inodes.
  mkdir -p "$(dirname "$lock")" || return 1
  exec {cache_fd}>"$lock" || return 1
  chmod 600 "$lock" || return 1
  flock -n -E 3 "$cache_fd" || return "$?"
  [[ -f "$entry" && ! -L "$entry" ]] || return 3
  expired="$(find "$entry" -maxdepth 0 -mtime "+$days" -print)" || return 1
  [[ -n "$expired" ]] || return 3
  rm -f -- "$entry" "$@"
)

case "${1:-status}" in
  status)
    count=0
    bytes=0
    if [[ -d "$objects" ]]; then
      count="$(find "$objects" -maxdepth 1 -type f | wc -l | tr -d ' ')"
      bytes="$(du -sb "$objects" | awk '{print $1}')"
    fi
    materials=0
    if [[ -d "$verification" ]]; then
      materials="$(find "$verification" -maxdepth 1 -type f ! -name '*.sha256' ! -name '*.lock' | wc -l | tr -d ' ')"
    fi
    printf 'Cache: %s\nObjects: %s\nBytes: %s\nVerification materials: %s\n' "$root" "$count" "$bytes" "$materials"
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
        key="${entry##*/}"
        [[ "$key" =~ ^[0-9a-f]{64}$ ]] || continue
        if prune_entry "$entry" "$root/locks/$key.lock" "$days"; then
          removed=$((removed + 1))
        else
          status=$?
          [[ "$status" == 3 ]] || exit "$status"
        fi
      done < <(find "$objects" -maxdepth 1 -type f -mtime "+$days" -print0)
    fi
    if [[ -d "$verification" ]]; then
      while IFS= read -r -d '' entry; do
        key="${entry##*/}"
        [[ "$key" =~ ^[0-9a-f]{64}$ ]] || continue
        if prune_entry "$entry" "$entry.lock" "$days" "$entry.sha256"; then
          :
        else
          status=$?
          [[ "$status" == 3 ]] || exit "$status"
        fi
      done < <(find "$verification" -maxdepth 1 -type f -mtime "+$days" -print0)
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
