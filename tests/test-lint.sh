#!/usr/bin/env bash
# Run the same file selection and linter options as CI; any failure is fatal.
set -euo pipefail
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$DOTFILES_DIR"
errors=0
mapfile -d '' -t files < <(
  find scripts tests -type f -name '*.sh' -print0
  find dot_local/bin -type f -name 'executable_*' ! -name '*.tmpl' -print0
)
for linter in shellcheck shfmt yamllint; do
  printf '\n== %s ==\n' "$linter"
  if ! command -v "$linter" >/dev/null 2>&1; then
    printf '[FAIL] Required linter is missing: %s\n' "$linter" >&2
    errors=$((errors + 1))
    continue
  fi
  case "$linter" in
    shellcheck) args=(-x -S warning -e 'SC1090,SC1091' "${files[@]}") ;;
    shfmt) args=(-d -i 2 -ci "${files[@]}") ;;
    yamllint) args=(.) ;;
  esac
  if ! "$linter" "${args[@]}"; then
    printf '[FAIL] %s\n' "$linter" >&2
    errors=$((errors + 1))
  fi
done
if ((errors)); then
  printf 'LINT FAILED (%s failed or missing linters)\n' "$errors" >&2
  exit 1
fi
printf 'ALL LINTS PASSED\n'
