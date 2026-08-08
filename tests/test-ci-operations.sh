#!/usr/bin/env bash
# Validate CI scheduling, classification, maintenance, and acceptance contracts.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
FAILED=0

pass() { printf '  [PASS] %s\n' "$*"; }
fail() {
  printf '  [FAIL] %s\n' "$*"
  FAILED=1
}

CI="$DOTFILES_DIR/.github/workflows/ci.yml"
OUTCOME="$DOTFILES_DIR/.github/workflows/ci-outcome.yml"
UPGRADES="$DOTFILES_DIR/.github/workflows/grouped-upgrades.yml"
NATIVE="$DOTFILES_DIR/.github/workflows/native-vm-e2e.yml"
DEPENDABOT="$DOTFILES_DIR/.github/dependabot.yml"

printf '\n== CI Operations ==\n'

if grep -Fq "github.event_name == 'workflow_dispatch' && github.run_id || github.ref" "$CI" &&
  grep -Fq "cancel-in-progress: \${{ github.event_name == 'push' || github.event_name == 'pull_request' }}" "$CI"; then
  pass 'CI concurrency is event-aware and preserves explicit manual runs'
else
  fail 'CI concurrency does not distinguish supersedable and explicit runs'
fi

if grep -Fq 'workflow_run:' "$OUTCOME" &&
  grep -Fq 'checks: write' "$OUTCOME" &&
  grep -Fq './scripts/classify-ci-run.sh' "$OUTCOME" &&
  ! grep -Fq 'ref: ${{ github.event.workflow_run.head_sha }}' "$OUTCOME"; then
  pass 'outcome classifier uses trusted default-branch code and publishes a check'
else
  fail 'outcome classifier is missing or checks out untrusted workflow code'
fi

if grep -Fq 'tests/test-network-faults.sh "$PWD"' "$CI" &&
  grep -Fq 'test-network-faults.sh' "$CI" &&
  grep -Fq 'tests/test-download-cache.sh "$PWD"' "$CI" &&
  grep -Fq 'test-download-cache.sh' "$CI" &&
  grep -Fq 'performance-history:' "$CI" &&
  grep -Fq 'name: performance-history' "$CI"; then
  pass 'network faults, verified cache, and rolling performance history are wired into CI'
else
  fail 'network fault, verified cache, or performance history coverage is not wired into CI'
fi

if grep -Fq 'cron: "17 4 1 * *"' "$UPGRADES" &&
  grep -Fq './scripts/update-packages.sh --apply-all' "$UPGRADES" &&
  grep -Fq 'branch=automation/grouped-tool-upgrades' "$UPGRADES" &&
  grep -Fq 'Validate generated update set in Docker' "$UPGRADES" &&
  [[ "$(grep -Fc 'gh pr create' "$UPGRADES")" == 1 ]] &&
  grep -Fq "github.head_ref == 'automation/grouped-tool-upgrades'" "$CI"; then
  pass 'monthly tool upgrades converge on one canary PR with heavy E2E'
else
  fail 'grouped upgrade workflow can create fragmented or under-tested PRs'
fi

if grep -Fq 'interval: "monthly"' "$DEPENDABOT" &&
  grep -Fq 'github-actions:' "$DEPENDABOT" &&
  grep -Fq 'patterns: ["*"]' "$DEPENDABOT"; then
  pass 'GitHub Actions updates are grouped into one monthly PR'
else
  fail 'Dependabot Actions updates are not grouped monthly'
fi

if grep -Fq 'runs-on: ubuntu-24.04' "$NATIVE" &&
  grep -Fq 'for pass in 1 2; do' "$NATIVE" &&
  grep -Fq -- '--with fonts,desktop' "$NATIVE" &&
  grep -Fq 'Seed native restore fixtures' "$NATIVE" &&
  grep -Fq 'Restore first backup and reapply' "$NATIVE" &&
  grep -Fq 'first-backup-manifest.tsv' "$NATIVE" &&
  grep -Fq './scripts/backup.sh restore "$backup_id" --force' "$NATIVE" &&
  grep -Fq 'bootstrap-reapply.log' "$NATIVE" &&
  grep -Fq 'DOTFILES_ALLOW_CI_LOGIN_SHELL_MUTATION: "1"' "$NATIVE" &&
  grep -Fq 'desktop-file-validate' "$NATIVE" &&
  grep -Fq 'systemd-analyze verify' "$NATIVE"; then
  pass 'native VM acceptance covers two-pass install, restore/reapply, and host integrations'
else
  fail 'native VM acceptance is missing a required host integration check'
fi

[[ "$FAILED" -eq 0 ]] || exit 1
printf 'CI operations test passed\n'
