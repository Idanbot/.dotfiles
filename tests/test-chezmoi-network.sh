#!/usr/bin/env bash
# Exercise rate limits and failed downloads without touching real services.
set -euo pipefail
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
export MOCK_CHEZMOI_ROOT="$temporary"
export DOTFILES_CHEZMOI_ATTEMPTS=3 DOTFILES_CHEZMOI_RETRY_DELAY=0
mkdir -p "$temporary/bin"
cat >"$temporary/bin/chezmoi" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f "$MOCK_CHEZMOI_ROOT/count" ]] || count="$(<"$MOCK_CHEZMOI_ROOT/count")"
printf '%s\n' "$((count + 1))" >"$MOCK_CHEZMOI_ROOT/count"
printf '%s\n' "$@" >"$MOCK_CHEZMOI_ROOT/args"
if ((count < 2)) || [[ "$MOCK_ERROR" == permanent || "$MOCK_ERROR" == checksum ]]; then
  printf 'partial status must not escape\n'
  case "$MOCK_ERROR" in
    rate | permanent) printf 'chezmoi: .fzf: https://example.invalid/archive: 429 Too Many Requests\n' >&2 ;;
    server) printf 'chezmoi: .fzf: https://example.invalid/archive: 503 Service Unavailable\n' >&2 ;;
    timeout) printf 'chezmoi: https://example.invalid/archive: TLS handshake timeout\n' >&2 ;;
    checksum) printf 'chezmoi: https://example.invalid/archive: checksum mismatch (expected abc429def503)\n' >&2 ;;
  esac
  exit 22
fi
printf 'MM .zshrc\n'
SH
chmod +x "$temporary/bin/chezmoi"
export PATH="$temporary/bin:$PATH"
# shellcheck source=scripts/chezmoi-network.sh
source "$DOTFILES_DIR/scripts/chezmoi-network.sh"
for MOCK_ERROR in rate server timeout; do
  export MOCK_ERROR
  rm -f "$temporary/count"
  result="$(chezmoi_with_retry status 2>"$temporary/stderr")"
  [[ "$result" == 'MM .zshrc' && "$(<"$temporary/count")" == 3 ]]
  grep -Fq 'retrying in 0s' "$temporary/stderr"
done
for MOCK_ERROR in permanent checksum; do
  export MOCK_ERROR
  rm -f "$temporary/count"
  if result="$(chezmoi_with_retry status 2>"$temporary/stderr")"; then
    printf '%s failure was ignored\n' "$MOCK_ERROR" >&2
    exit 1
  else
    [[ "$?" == 22 && -z "$result" ]]
  fi
  expected=3
  [[ "$MOCK_ERROR" != checksum ]] || expected=1
  [[ "$(<"$temporary/count")" == "$expected" ]]
done
export MOCK_ERROR=rate
rm -f "$temporary/count"
chezmoi_with_retry apply --exclude=scripts --no-tty "$temporary/a file" >/dev/null
grep -Fxq "$temporary/a file" "$temporary/args"
/usr/bin/python3 - "$DOTFILES_DIR/.chezmoiexternal.yaml" <<'PY'
import sys
import yaml
with open(sys.argv[1]) as stream:
    externals = yaml.safe_load(stream)
assert all(entry.get('refreshPeriod', 0) == 0 for entry in externals.values())
assert all(entry.get('checksum', {}).get('sha256') for entry in externals.values())
PY
printf 'Chezmoi network retry and immutable cache tests passed\n'
