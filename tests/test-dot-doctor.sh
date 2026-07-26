#!/usr/bin/env bash
# Ensure dot doctor can recover the source used by a local/container install.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SYSTEM_PATH="$PATH"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/home/.local/state/dotfiles" "$TMP_ROOT/bin"
chmod 700 "$TMP_ROOT/home/.local/state/dotfiles"
printf '%s\n' "$DOTFILES_DIR" >"$TMP_ROOT/home/.local/state/dotfiles/source"
cat >"$TMP_ROOT/bin/chezmoi" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == source-path ]] && printf '/missing/chezmoi/source\n'
EOF
chmod +x "$TMP_ROOT/bin/chezmoi"

HOME="$TMP_ROOT/home" \
  DOTFILES_STATE_DIR="$TMP_ROOT/home/.local/state/dotfiles" \
  PATH="$TMP_ROOT/bin:$SYSTEM_PATH" \
  "$DOTFILES_DIR/dot_local/bin/executable_dot" doctor --help |
  grep -Fq -- '--strict'

grep -Fq "sed '\\|^[[:space:]]*run[[:space:]]\\+-b.*tpm/tpm|d'" \
  "$DOTFILES_DIR/scripts/doctor.sh"

json_output="$(
  HOME="$TMP_ROOT/home" \
    DOTFILES_SOURCE_DIR="$DOTFILES_DIR" \
    DOTFILES_STATE_DIR="$TMP_ROOT/home/.local/state/dotfiles" \
    PATH="$TMP_ROOT/bin:$SYSTEM_PATH" \
    "$DOTFILES_DIR/scripts/doctor.sh" --sections detect --quick --json
)"
python3 -c '
import json, sys
report = json.load(sys.stdin)
assert report["schema_version"] == 1
assert report["healthy"] is True
assert report["sections"] == ["detect"]
assert report["checks"] >= 5
assert report["warnings"] == 1
' <<<"$json_output"

if HOME="$TMP_ROOT/home" \
  DOTFILES_SOURCE_DIR="$DOTFILES_DIR" \
  DOTFILES_STATE_DIR="$TMP_ROOT/home/.local/state/dotfiles" \
  PATH="$TMP_ROOT/bin:$SYSTEM_PATH" \
  "$DOTFILES_DIR/scripts/doctor.sh" --sections detect --quick --strict >/dev/null; then
  echo "Doctor strict mode accepted a warning" >&2
  exit 1
fi

if "$DOTFILES_DIR/scripts/doctor.sh" --sections detect,unknown --quick >/dev/null 2>&1; then
  echo "Doctor accepted an unknown section" >&2
  exit 1
fi

printf 'broken\trow\n' >"$TMP_ROOT/home/.local/state/dotfiles/installed.tsv"
if HOME="$TMP_ROOT/home" \
  DOTFILES_SOURCE_DIR="$DOTFILES_DIR" \
  DOTFILES_STATE_DIR="$TMP_ROOT/home/.local/state/dotfiles" \
  PATH="$TMP_ROOT/bin:$SYSTEM_PATH" \
  "$DOTFILES_DIR/scripts/doctor.sh" --sections detect --quick --json >/dev/null; then
  echo "Doctor accepted a malformed install ledger" >&2
  exit 1
fi

printf 'Dot doctor source recovery test passed\n'
