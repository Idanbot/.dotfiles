#!/usr/bin/env bash
# Cache transport only: missing/corrupt caches rebuild; CI artifacts fail closed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command="${1:?usage: validator-image.sh ensure|load DIRECTORY [IMAGE] [PERIOD]}"
directory="${2:?cache directory required}"
image="${3:-dotfiles-ci-tests}"
archive="$directory/test-image.tar.zst"

verify_archive() {
  local checksum image_id
  [[ -f "$archive" && ! -L "$archive" && -f "$archive.sha256" && -f "$directory/image.id" ]] || return 1
  [[ ! -L "$archive.sha256" && ! -L "$directory/image.id" ]] || return 1
  checksum="$(<"$archive.sha256")"
  image_id="$(<"$directory/image.id")"
  [[ "$checksum" =~ ^[a-f0-9]{64}$ && "$image_id" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
  [[ "$(sha256sum "$archive" | awk '{print $1}')" == "$checksum" ]] || return 1
  zstd -tq "$archive" || return 1
}

load_archive() {
  verify_archive || return 1
  zstd -dc "$archive" | docker load || return 1
  [[ "$(docker image inspect --format '{{.Id}}' "$image")" == "$(<"$directory/image.id")" ]]
}

case "$command" in
  load) load_archive ;;
  ensure)
    mkdir -p "$directory"
    period="${4:?refresh period required}"
    identity="${5:-$period}"
    hit=false
    started="$(date +%s%N)"
    if [[ -f "$directory/cache.identity" && ! -L "$directory/cache.identity" && "$(<"$directory/cache.identity")" == "$identity" &&
    -f "$directory/cache.period" && ! -L "$directory/cache.period" && "$(<"$directory/cache.period")" == "$period" ]] && load_archive; then
      hit=true
      printf 'Verified validator image cache hit\n'
    else
      printf 'Validator cache missing or invalid; building from reviewed inputs\n'
      rm -f "$archive" "$archive.sha256" "$directory/image.id" "$directory/cache.identity" "$directory/cache.period"
      docker build --pull --target tests \
        --build-arg "VALIDATOR_REFRESH=$period" \
        -f "$ROOT/.github/e2e/Dockerfile.ubuntu-24.04" -t "$image" "$ROOT"
      docker save "$image" | zstd -T2 -3 -o "$archive"
      sha256sum "$archive" | awk '{print $1}' >"$archive.sha256"
      docker image inspect --format '{{.Id}}' "$image" >"$directory/image.id"
      printf '%s\n' "$identity" >"$directory/cache.identity"
      printf '%s\n' "$period" >"$directory/cache.period"
      verify_archive
    fi
    [[ -z "${GITHUB_OUTPUT:-}" ]] || printf 'hit=%s\n' "$hit" >>"$GITHUB_OUTPUT"
    # shellcheck source=scripts/performance-format.sh
    source "$ROOT/scripts/performance-format.sh"
    elapsed_ms="$((($(date +%s%N) - started) / 1000000))"
    {
      printf '### Validator Image\n\n'
      printf -- '- Verified cache hit: `%s`\n' "$hit"
      printf -- '- Image bytes: `%s`; compressed bytes: `%s`\n' \
        "$(docker image inspect --format '{{.Size}}' "$image")" "$(stat -c '%s' "$archive")"
      printf -- '- Preparation: %s\n' "$(format_duration_ms "$elapsed_ms")"
    } >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
    ;;
  *)
    printf 'Unknown validator image command: %s\n' "$command" >&2
    exit 2
    ;;
esac
