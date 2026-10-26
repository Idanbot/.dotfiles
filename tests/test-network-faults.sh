#!/usr/bin/env bash
# Inject deterministic transport and integrity failures at the download boundary.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
MOCK_BIN="$TMP_ROOT/bin"
MOCK_STATE="$TMP_ROOT/state"
mkdir -p "$MOCK_BIN" "$MOCK_STATE" "$TMP_ROOT/home"
printf 'verified payload\n' >"$MOCK_STATE/payload"

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
count_file="$MOCK_CURL_STATE/$key.count"
count=0
[[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"

case "$key" in
  transient)
    ((count >= 3)) || exit 22
    cp "$MOCK_CURL_STATE/payload" "$dest"
    ;;
  permanent)
    printf 'partial response\n' >"$dest"
    exit 28
    ;;
  corrupt)
    printf 'truncated response\n' >"$dest"
    ;;
  valid)
    cp "$MOCK_CURL_STATE/payload" "$dest"
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
export DOTFILES_DOWNLOAD_ATTEMPTS=3
export DOTFILES_DOWNLOAD_RETRY_DELAY=0
# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

download https://example.invalid/transient "$TMP_ROOT/transient.out" >/dev/null
cmp "$MOCK_STATE/payload" "$TMP_ROOT/transient.out"
[[ "$(cat "$MOCK_STATE/transient.count")" == 3 ]]

printf 'trusted old payload\n' >"$TMP_ROOT/permanent.out"
if download https://example.invalid/permanent "$TMP_ROOT/permanent.out" >/dev/null 2>&1; then
  printf 'Permanent transport failure unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fxq 'trusted old payload' "$TMP_ROOT/permanent.out"
if find "$TMP_ROOT" -maxdepth 1 -name '*.part.*' | grep -q .; then
  printf 'Failed transport left partial files behind\n' >&2
  exit 1
fi

expected="$(sha256sum "$MOCK_STATE/payload" | awk '{print $1}')"
printf 'trusted verified payload\n' >"$TMP_ROOT/verified.out"
if download_verified \
  https://example.invalid/corrupt \
  "$TMP_ROOT/verified.out" \
  "sha256:$expected" >/dev/null 2>&1; then
  printf 'Corrupt payload unexpectedly passed checksum validation\n' >&2
  exit 1
fi
grep -Fxq 'trusted verified payload' "$TMP_ROOT/verified.out"

download_verified \
  https://example.invalid/valid \
  "$TMP_ROOT/verified.out" \
  "sha256:$expected" >/dev/null
cmp "$MOCK_STATE/payload" "$TMP_ROOT/verified.out"

# Command substitutions must capture only data, even after a recovered retry.
(
  export DOTFILES_EVENT_LOG="$TMP_ROOT/retry-events.jsonl"
  index_count_file="$TMP_ROOT/index-attempts"
  download_once() {
    local count=0
    [[ ! -f "$index_count_file" ]] || count="$(<"$index_count_file")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$index_count_file"
    ((count >= ${INDEX_SUCCEED_AFTER:-2})) || return 28
    printf '[{"files":[{"filename":"go-test.tar.gz","sha256":"%s"}]}]\n' "$expected" >"$2"
  }
  checksum="$(go_release_checksum go-test.tar.gz 2>"$TMP_ROOT/retry.stderr")"
  [[ "$checksum" == "$expected" ]]
  grep -q '\[WARN\].*retrying' "$TMP_ROOT/retry.stderr"
  grep -q '"level":"warn"' "$DOTFILES_EVENT_LOG"
  INDEX_SUCCEED_AFTER=1
  rm "$index_count_file"
  checksum="$(go_release_checksum go-test.tar.gz 2>"$TMP_ROOT/immediate.stderr")"
  [[ "$checksum" == "$expected" && ! -s "$TMP_ROOT/immediate.stderr" ]]
  INDEX_SUCCEED_AFTER=99
  rm "$index_count_file"
  checksum=""
  if checksum="$(go_release_checksum go-test.tar.gz 2>"$TMP_ROOT/exhausted.stderr")"; then
    printf 'Exhausted metadata retries unexpectedly succeeded\n' >&2
    exit 1
  else
    [[ "$?" == 28 ]]
  fi
  [[ -z "$checksum" && "$(<"$index_count_file")" == 3 ]]
  grep -q '\[ERROR\].*failed after 3 attempts' "$TMP_ROOT/exhausted.stderr"
  status=0
  retry_command fixture 2 0 bash -c 'exit 28' >"$TMP_ROOT/status.stdout" 2>"$TMP_ROOT/status.stderr" || status=$?
  [[ "$status" == 28 && ! -s "$TMP_ROOT/status.stdout" ]]
)

printf 'Network fault-injection test passed\n'
