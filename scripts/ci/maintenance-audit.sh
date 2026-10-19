#!/usr/bin/env bash
# Shared daily/weekly reporting; the public audit CLIs remain unchanged.
set -euo pipefail
mode="${1:?usage: maintenance-audit.sh daily|weekly REPORT}"
report="${2:?report path required}"
case "$mode" in
  daily) : >"$report" ;;
  weekly)
    ./scripts/update-packages.sh --check --report "$report"
    python3 scripts/install-policy.py recommendations >>"$report"
    ;;
  *)
    printf 'Unknown audit mode: %s\n' "$mode" >&2
    exit 2
    ;;
esac
python3 scripts/audit-vulnerabilities.py \
  --upgrade-report-url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-Idanbot/.dotfiles}/issues/34" \
  >>"$report"
cat "$report" >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
if [[ "$mode" == weekly ]]; then
  python3 scripts/publish-upgrade-report.py "$report"
fi
