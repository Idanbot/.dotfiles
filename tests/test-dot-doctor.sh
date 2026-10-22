#!/usr/bin/env bash
# Ensure dot doctor can recover the source used by a local/container install.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SYSTEM_PATH="$PATH"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home" XDG_CONFIG_HOME="$TMP_ROOT/home/.config"
export XDG_DATA_HOME="$TMP_ROOT/home/.local/share" XDG_STATE_HOME="$TMP_ROOT/home/.local/state"
export DOTFILES_STATE_DIR="$XDG_STATE_HOME/dotfiles"
export DOTFILES_SOURCE_DIR="$TMP_ROOT/source"
export PATH="$TMP_ROOT/bin:$SYSTEM_PATH"
mkdir -p "$DOTFILES_STATE_DIR" "$TMP_ROOT/bin" "$DOTFILES_SOURCE_DIR/.git"
chmod 700 "$DOTFILES_STATE_DIR"
cp -a "$DOTFILES_DIR/scripts" "$DOTFILES_SOURCE_DIR/scripts"
cp -a "$DOTFILES_DIR/.chezmoiscripts" "$DOTFILES_SOURCE_DIR/.chezmoiscripts"
cp "$DOTFILES_DIR/packages.yaml" "$DOTFILES_DIR/packages.meta.yaml" "$DOTFILES_SOURCE_DIR/"
printf '%s\n' "$DOTFILES_SOURCE_DIR" >"$DOTFILES_STATE_DIR/source"
printf '#!/bin/sh\nexit 0\n' >"$DOTFILES_SOURCE_DIR/scripts/validate-neovim.sh"
cat >"$TMP_ROOT/bin/chezmoi" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == source-path ]] && printf '/missing/chezmoi/source\n'
EOF
chmod +x "$TMP_ROOT/bin/chezmoi"

HOME="$TMP_ROOT/home" \
  DOTFILES_SOURCE_DIR='' \
  DOTFILES_STATE_DIR="$TMP_ROOT/home/.local/state/dotfiles" \
  PATH="$TMP_ROOT/bin:$SYSTEM_PATH" \
  "$DOTFILES_DIR/dot_local/bin/executable_dot" doctor --help |
  grep -Fq -- '--strict'

grep -Fq "sed '\\|^[[:space:]]*run[[:space:]]\\+-b.*tpm/tpm|d'" \
  "$DOTFILES_DIR/scripts/doctor.sh"

json_output="$(
  HOME="$TMP_ROOT/home" \
    DOTFILES_SOURCE_DIR="$TMP_ROOT/source" \
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
  DOTFILES_SOURCE_DIR="$TMP_ROOT/source" \
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

cat >"$TMP_ROOT/bin/fc-list" <<'EOF'
#!/usr/bin/env bash
printf 'FiraMono Nerd Font\n'
for ((i = 0; i < 10000; i++)); do
  printf 'Unrelated Font %s\n' "$i"
done
EOF
chmod +x "$TMP_ROOT/bin/fc-list"
chmod 755 "$TMP_ROOT/home/.local/state/dotfiles"
registered_font_json="$(
  HOME="$TMP_ROOT/home" \
    DOTFILES_SOURCE_DIR="$TMP_ROOT/source" \
    DOTFILES_STATE_DIR="$TMP_ROOT/home/.local/state/dotfiles" \
    PATH="$TMP_ROOT/bin:$SYSTEM_PATH" \
    "$DOTFILES_DIR/scripts/doctor.sh" --sections fonts --quick --json
)"
python3 -c '
import json, sys
report = json.load(sys.stdin)
assert report["healthy"] is True
assert any(
    result["name"] == "nerd-font"
    and result["state"] == "pass"
    and "fontconfig" in result["detail"]
    for result in report["results"]
)
' <<<"$registered_font_json"
[[ "$(stat -c '%a' "$TMP_ROOT/home/.local/state/dotfiles")" == 700 ]]

mkdir -p "$TMP_ROOT/home/.local/share/fonts/FiraMono"
printf 'font fixture\n' \
  >"$TMP_ROOT/home/.local/share/fonts/FiraMono/FiraMonoNerdFont-Regular.otf"
cat >"$TMP_ROOT/bin/fc-list" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP_ROOT/bin/fc-list"
font_json="$(
  HOME="$TMP_ROOT/home" \
    DOTFILES_SOURCE_DIR="$TMP_ROOT/source" \
    DOTFILES_STATE_DIR="$TMP_ROOT/home/.local/state/dotfiles" \
    PATH="$TMP_ROOT/bin:$SYSTEM_PATH" \
    "$DOTFILES_DIR/scripts/doctor.sh" --sections fonts --quick --json
)"
python3 -c '
import json, sys
report = json.load(sys.stdin)
assert report["healthy"] is True
assert any(
    result["name"] == "nerd-font" and result["state"] == "pass"
    for result in report["results"]
)
' <<<"$font_json"

printf 'broken\trow\n' >"$TMP_ROOT/home/.local/state/dotfiles/installed.tsv"
if HOME="$TMP_ROOT/home" \
  DOTFILES_SOURCE_DIR="$TMP_ROOT/source" \
  DOTFILES_STATE_DIR="$TMP_ROOT/home/.local/state/dotfiles" \
  PATH="$TMP_ROOT/bin:$SYSTEM_PATH" \
  "$DOTFILES_DIR/scripts/doctor.sh" --sections detect --quick --json >/dev/null; then
  echo "Doctor accepted a malformed install ledger" >&2
  exit 1
fi

rm "$DOTFILES_STATE_DIR/installed.tsv"
doctor() { "$DOTFILES_SOURCE_DIR/scripts/doctor.sh" "$@"; }
assert_sections() {
  /usr/bin/python3 -c '
import json, sys
report = json.load(sys.stdin)
assert report["sections"] == sys.argv[1].split(","), report["sections"]
' "$1"
}

# The persisted selection is authoritative, not the machine profile or all tools.
printf 'detect\n' >"$DOTFILES_STATE_DIR/selected-sections"
mkdir -p "$XDG_CONFIG_HOME/dotfiles" "$DOTFILES_STATE_DIR/runs/previous"
printf 'profile=full\n' >"$XDG_CONFIG_HOME/dotfiles/machine.conf"
chmod 600 "$XDG_CONFIG_HOME/dotfiles/machine.conf"
printf '{"status":"success","sections":"fonts"}\n' \
  >"$DOTFILES_STATE_DIR/runs/previous/summary.json"
selection_failures=0
for scenario in persisted override all fallback missing invalid; do
  case "$scenario" in
    persisted)
      doctor --quick --json >"$TMP_ROOT/selection.json" || true
      expected=detect
      ;;
    override)
      doctor --sections fonts --quick --json >"$TMP_ROOT/selection.json" || true
      expected=fonts
      ;;
    all)
      doctor --all --quick --json >"$TMP_ROOT/selection.json" 2>"$TMP_ROOT/selection.err" || true
      expected="$(/usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/section-state.py" \
        --source "$DOTFILES_SOURCE_DIR" list | paste -sd, -)"
      ;;
    fallback)
      rm "$DOTFILES_STATE_DIR/selected-sections"
      doctor --quick --json >"$TMP_ROOT/selection.json" || true
      expected=fonts
      ;;
    missing)
      rm "$DOTFILES_STATE_DIR/runs/previous/summary.json"
      exit_code=0
      doctor --quick >"$TMP_ROOT/selection.out" 2>&1 || exit_code=$?
      if [[ "$exit_code" != 2 ]]; then
        printf 'Doctor silently checked all sections without installed selection\n' >&2
        ((selection_failures += 1))
      fi
      if ! grep -Fq -- '--sections' "$TMP_ROOT/selection.out"; then
        printf 'Doctor did not explain missing installed selection\n' >&2
        ((selection_failures += 1))
      fi
      continue
      ;;
    invalid)
      printf 'detect,unknown\n' >"$DOTFILES_STATE_DIR/selected-sections"
      exit_code=0
      doctor --quick >"$TMP_ROOT/selection.out" 2>&1 || exit_code=$?
      if [[ "$exit_code" != 2 ]]; then
        printf 'Doctor accepted invalid persisted selection\n' >&2
        ((selection_failures += 1))
      fi
      continue
      ;;
  esac
  if ! assert_sections "$expected" <"$TMP_ROOT/selection.json"; then
    printf 'Doctor selection regression failed: %s\n' "$scenario" >&2
    ((selection_failures += 1))
  fi
done

mkdir -p "$HOME/.oh-my-zsh"
printf ':\n' >"$HOME/.oh-my-zsh/oh-my-zsh.sh"
startup_failures=0
for scenario in valid syntax source quick-syntax; do
  options=(--sections zsh --json)
  expected=fail
  case "$scenario" in
    valid)
      printf ':\n' >"$HOME/.zshrc"
      expected=pass
      ;;
    syntax | quick-syntax)
      printf 'if then\nprivate-doctor-sentinel\n' >"$HOME/.zshrc"
      [[ "$scenario" != quick-syntax ]] || options+=(--quick)
      ;;
    source)
      printf 'printf "private-doctor-sentinel\\n"\nprintf "private-doctor-sentinel\\n" >&2\nreturn 23\n' >"$HOME/.zshrc"
      ;;
  esac
  exit_code=0
  doctor "${options[@]}" >"$TMP_ROOT/startup.json" 2>"$TMP_ROOT/startup.err" || exit_code=$?
  if ! /usr/bin/python3 - "$TMP_ROOT/startup.json" "$expected" "$exit_code" <<'PY'; then
import json
import sys

report = json.load(open(sys.argv[1]))
expected, code = sys.argv[2:]
checks = [item for item in report["results"] if item["name"] in {"zsh-syntax", "zsh-startup"}]
assert checks, report
if expected == "pass":
    assert code == "0" and report["healthy"] is True, report
    assert all(item["state"] == "pass" for item in checks), checks
else:
    assert code == "1" and report["healthy"] is False, report
    assert any(item["state"] == "fail" for item in checks), checks
PY
    printf 'Doctor startup regression failed: %s\n' "$scenario" >&2
    ((startup_failures += 1))
  fi
  if grep -Fq private-doctor-sentinel "$TMP_ROOT/startup.json" "$TMP_ROOT/startup.err"; then
    printf 'Doctor exposed startup output: %s\n' "$scenario" >&2
    ((startup_failures += 1))
  fi
done
[[ "$selection_failures" == 0 && "$startup_failures" == 0 ]]

printf 'Dot doctor source recovery test passed\n'
