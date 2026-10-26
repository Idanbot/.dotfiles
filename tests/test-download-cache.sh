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
[[ "$(request_count checksums.txt)" == 1 ]]
manifest_key="$(printf '%s' https://example.invalid/checksums.txt | sha256sum | awk '{print $1}')"
printf 'corrupt\n' >"$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key"
download_verified https://example.invalid/manifest-asset "$TMP_ROOT/manifest-recovered" \
  https://example.invalid/checksums.txt manifest-asset >/dev/null
[[ "$(request_count checksums.txt)" == 2 ]]
cmp "$MOCK_STATE/manifest-payload" "$TMP_ROOT/manifest-recovered"

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

# Hold real reader locks while prune runs in another process, without sleeps.
payload_lock="$DOTFILES_DOWNLOAD_CACHE_DIR/locks/$primary_sha.lock"
exec {payload_fd}>"$payload_lock"
flock -x "$payload_fd"
exec {material_fd}>"$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key.lock"
flock -x "$material_fd"
touch -d '45 days ago' "$payload_lock" "$DOTFILES_DOWNLOAD_CACHE_DIR/sha256/$primary_sha" \
  "$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key" \
  "$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key.sha256" \
  "$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key.lock"
payload_inode="$(stat -c '%i' "$payload_lock")"
staging="$DOTFILES_DOWNLOAD_CACHE_DIR/verification/.download.active"
printf 'active staging\n' >"$staging"
touch -d '45 days ago' "$staging"
DOTFILES_DOWNLOAD_CACHE_DIR="$DOTFILES_DOWNLOAD_CACHE_DIR" \
  "$DOTFILES_DIR/scripts/download-cache.sh" prune 30 >/dev/null
[[ ! -e "$old_entry" ]]
[[ -f "$DOTFILES_DOWNLOAD_CACHE_DIR/sha256/$primary_sha" ]]
[[ -f "$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key" ]]
[[ -f "$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key.sha256" && -f "$staging" ]]
[[ "$(stat -c '%i' "$payload_lock")" == "$payload_inode" ]]
if flock -n "$payload_lock" true || flock -n "$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key.lock" true; then
  printf 'Prune broke an active cache lock\n' >&2
  exit 1
fi
flock -u "$payload_fd"
exec {payload_fd}>&-
flock -u "$material_fd"
exec {material_fd}>&-

# Age is rechecked under lock; a cache hit refreshes retention for both types.
download_verified https://example.invalid/primary "$TMP_ROOT/refreshed" \
  "sha256:$primary_sha" primary >/dev/null
download_verified https://example.invalid/manifest-asset "$TMP_ROOT/manifest-refreshed" \
  https://example.invalid/checksums.txt manifest-asset >/dev/null
"$DOTFILES_DIR/scripts/download-cache.sh" prune 30 >/dev/null
[[ -f "$DOTFILES_DOWNLOAD_CACHE_DIR/sha256/$primary_sha" ]]
[[ -f "$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key.sha256" ]]
[[ "$(request_count primary)" == 3 && "$(request_count checksums.txt)" == 2 ]]

# Idle verification content and digest are one entry, even with different ages.
touch -d '45 days ago' "$DOTFILES_DOWNLOAD_CACHE_DIR/sha256/$primary_sha" \
  "$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key"
"$DOTFILES_DIR/scripts/download-cache.sh" prune 30 >/dev/null
[[ ! -e "$DOTFILES_DOWNLOAD_CACHE_DIR/sha256/$primary_sha" ]]
[[ ! -e "$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key" ]]
[[ ! -e "$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key.sha256" ]]
[[ -f "$payload_lock" && -f "$DOTFILES_DOWNLOAD_CACHE_DIR/verification/$manifest_key.lock" ]]
[[ -f "$staging" ]]
"$DOTFILES_DIR/scripts/download-cache.sh" prune 30 >/dev/null

# A reader can refresh an entry after find selects it but before prune locks it.
race_key="$(printf 'e%.0s' {1..64})"
export RACE_ENTRY="$DOTFILES_DOWNLOAD_CACHE_DIR/sha256/$race_key"
printf 'refreshed during scan\n' >"$RACE_ENTRY"
touch -d '45 days ago' "$RACE_ENTRY"
cat >"$MOCK_BIN/flock" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -n ]]; then
  touch "$RACE_ENTRY"
fi
exec /usr/bin/flock "$@"
EOF
chmod +x "$MOCK_BIN/flock"
"$DOTFILES_DIR/scripts/download-cache.sh" prune 30 >/dev/null
[[ -f "$RACE_ENTRY" ]]
rm "$MOCK_BIN/flock"

# A real cleanup error must not be mistaken for a busy entry and hidden.
touch -d '45 days ago' "$RACE_ENTRY"
cat >"$MOCK_BIN/rm" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  [[ "$argument" != "$RACE_ENTRY" ]] || exit 1
done
exec /usr/bin/rm "$@"
EOF
chmod +x "$MOCK_BIN/rm"
if "$DOTFILES_DIR/scripts/download-cache.sh" prune 30 >/dev/null 2>&1; then
  printf 'Cache removal failure was silently ignored\n' >&2
  exit 1
fi
[[ -f "$RACE_ENTRY" ]]
/usr/bin/rm "$MOCK_BIN/rm"
if "$DOTFILES_DIR/scripts/download-cache.sh" prune invalid >/dev/null 2>&1; then
  printf 'Invalid prune age unexpectedly accepted\n' >&2
  exit 1
fi
"$DOTFILES_DIR/scripts/download-cache.sh" status | grep -Fq "Cache: $DOTFILES_DOWNLOAD_CACHE_DIR"

printf 'Verified download cache test passed\n'
