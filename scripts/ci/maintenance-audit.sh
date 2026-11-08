#!/usr/bin/env bash
# Shared daily/weekly reporting; the public audit CLIs remain unchanged.
set -euo pipefail
mode="${1:?usage: maintenance-audit.sh daily|weekly REPORT [--no-publish]}"
report="${2:?report path required}"
publish=true
case "${3:-}" in
  '') ;;
  --no-publish) publish=false ;;
  *)
    printf 'Unknown audit option: %s\n' "$3" >&2
    exit 2
    ;;
esac
(($# <= 3)) || exit 2
case "$mode" in
  daily | weekly) ;;
  *)
    printf 'Unknown audit mode: %s\n' "$mode" >&2
    exit 2
    ;;
esac
mkdir -p "$(dirname "$report")"
temporary="$(mktemp -d "$(dirname "$report")/.audit.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
failed=0
touch "$temporary/body"

append_section() {
  local label="$1"
  shift
  if "$@" >"$temporary/section"; then
    cat "$temporary/section" >>"$temporary/body"
  else
    failed=1
    printf '\n## Incomplete: %s\n\nThis stage failed. No current results are available for this section.\n' \
      "$label" >>"$temporary/body"
  fi
}

upgrade_section() {
  ./scripts/update-packages.sh --check --report "$temporary/upgrades.md" >/dev/null || return 1
  cat "$temporary/upgrades.md"
}

if [[ "$mode" == weekly ]]; then
  append_section 'version and checksum discovery' upgrade_section
  append_section 'stable recommendations' python3 scripts/install-policy.py recommendations
fi
append_section 'pinned-version CVEs' python3 scripts/audit-vulnerabilities.py \
  --upgrade-report-url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-Idanbot/.dotfiles}/issues/34"
{
  printf '# Dotfiles Maintenance Audit\n\nGenerated (UTC): `%s`  \nSource revision: `%s`  \n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git rev-parse HEAD 2>/dev/null || printf unavailable)"
  if ((failed)); then
    printf '**Status: incomplete**. Do not treat missing sections or previous reports as current.\n\n'
  else
    printf '**Status: complete**. All audit stages finished; review warnings and coverage limits below.\n\n'
  fi
  cat "$temporary/body"
} >"$temporary/report"
mv -f "$temporary/report" "$report"
cat "$report" >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
if [[ "$mode" == weekly && "$publish" == true ]]; then
  python3 scripts/publish-upgrade-report.py "$report"
fi
exit "$failed"
