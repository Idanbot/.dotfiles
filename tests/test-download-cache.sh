#!/usr/bin/env bash
# Verify content-addressed cache hits, integrity recovery, locking, and pruning.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
MOCK_BIN="$TMP_ROOT/bin"
MOCK_STATE="$TMP_ROOT/state"
mkdir -p "$MOCK_BIN" "$MOCK_STATE" "$TMP_ROOT/home"
printf 'primary payload\n' >"$MOCK_STATE/primary"
printf 'manifest payload\n' >"$MOCK_STATE/manifest-payload"
printf 'concurrent payload\n' >"$MOCK_STATE/concurrent"

cat >"$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

dest=""
url=""
while (($#)); do
  case "$1" in
    -o)
      dest="$2"
      shift 2
      ;;
    http://* | https://*)
      url="$1"
      shift
      ;;
    *) shift ;;
  esac
done

key="${url##*/}"
printf '%s\n' "$key" >>"$MOCK_CURL_STATE/requests"
case "$key" in
  primary) cp "$MOCK_CURL_STATE/primary" "$dest" ;;
  manifest-asset) cp "$MOCK_CURL_STATE/manifest-payload" "$dest" ;;
  checksums.txt)
    hash="$(sha256sum "$MOCK_CURL_STATE/manifest-payload" | awk '{print $1}')"
    printf '%s  manifest-asset\n' "$hash" >"$dest"
    ;;
  concurrent)
    sleep 1
    cp "$MOCK_CURL_STATE/concurrent" "$dest"
    ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$MOCK_BIN/curl"

export HOME="$TMP_ROOT/home"
export PATH="$MOCK_BIN:/usr/bin:/bin"
export MOCK_CURL_STATE="$MOCK_STATE"
export DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
export DOTFILES_COLOR=never
export DOTFILES_DOWNLOAD_ATTEMPTS=1
export DOTFILES_DOWNLOAD_RETRY_DELAY=0
export DOTFILES_DOWNLOAD_CACHE_DIR="$TMP_ROOT/cache"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

request_count() {
  local key="$1"
  grep -Fxc "$key" "$MOCK_STATE/requests" 2>/dev/null || true
}

primary_sha="$(sha256sum "$MOCK_STATE/primary" | awk '{print $1}')"
download_verified https://example.invalid/primary "$TMP_ROOT/first" \
  "sha256:$primary_sha" primary >/dev/null
download_verified https://example.invalid/primary "$TMP_ROOT/second" \
  "sha256:$primary_sha" primary >/dev/null
cmp "$TMP_ROOT/first" "$TMP_ROOT/second"
[[ "$(request_count primary)" == 1 ]]
[[ "$(stat -c '%a' "$DOTFILES_DOWNLOAD_CACHE_DIR")" == 700 ]]
[[ "$(stat -c '%a' "$DOTFILES_DOWNLOAD_CACHE_DIR/sha256/$primary_sha")" == 600 ]]

printf 'corrupt\n' >"$DOTFILES_DOWNLOAD_CACHE_DIR/sha256/$primary_sha"
download_verified https://example.invalid/primary "$TMP_ROOT/recovered" \
  "sha256:$primary_sha" primary >/dev/null
cmp "$MOCK_STATE/primary" "$TMP_ROOT/recovered"
[[ "$(request_count primary)" == 2 ]]

DOTFILES_DOWNLOAD_CACHE=0 download_verified \
  https://example.invalid/primary "$TMP_ROOT/uncached" \
  "sha256:$primary_sha" primary >/dev/null
[[ "$(request_count primary)" == 3 ]]

download_verified https://example.invalid/manifest-asset "$TMP_ROOT/manifest-first" \
  https://example.invalid/checksums.txt manifest-asset >/dev/null
download_verified https://example.invalid/manifest-asset "$TMP_ROOT/manifest-second" \
  https://example.invalid/checksums.txt manifest-asset >/dev/null
cmp "$MOCK_STATE/manifest-payload" "$TMP_ROOT/manifest-second"
[[ "$(request_count manifest-asset)" == 1 ]]
[[ "$(request_count checksums.txt)" == 2 ]]

concurrent_sha="$(sha256sum "$MOCK_STATE/concurrent" | awk '{print $1}')"
download_verified https://example.invalid/concurrent "$TMP_ROOT/concurrent-one" \
  "sha256:$concurrent_sha" concurrent >/dev/null &
first_pid=$!
download_verified https://example.invalid/concurrent "$TMP_ROOT/concurrent-two" \
  "sha256:$concurrent_sha" concurrent >/dev/null &
second_pid=$!
wait "$first_pid" "$second_pid"
cmp "$TMP_ROOT/concurrent-one" "$TMP_ROOT/concurrent-two"
[[ "$(request_count concurrent)" == 1 ]]

old_entry="$DOTFILES_DOWNLOAD_CACHE_DIR/sha256/$(printf 'f%.0s' {1..64})"
printf 'old\n' >"$old_entry"
touch -d '45 days ago' "$old_entry"
DOTFILES_DOWNLOAD_CACHE_DIR="$DOTFILES_DOWNLOAD_CACHE_DIR" \
  "$DOTFILES_DIR/scripts/download-cache.sh" prune 30 >/dev/null
[[ ! -e "$old_entry" ]]
"$DOTFILES_DIR/scripts/download-cache.sh" status | grep -Fq "Cache: $DOTFILES_DOWNLOAD_CACHE_DIR"

printf 'Verified download cache test passed\n'
