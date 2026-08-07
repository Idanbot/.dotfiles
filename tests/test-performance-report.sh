#!/usr/bin/env bash
# Verify report-only performance regressions and opt-in enforcement.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ARTIFACT_DIR="$TMP_ROOT/artifacts"
MOCK_BIN="$TMP_ROOT/bin"

mkdir -p "$ARTIFACT_DIR" "$MOCK_BIN"
cat >"$MOCK_BIN/starship" <<'EOF'
#!/usr/bin/env bash
sleep 0.02
EOF
chmod +x "$MOCK_BIN/starship"
printf '{"budget_ms":1000,"median_ms":12,"runs_ms":[10,12,14]}\n' \
  >"$ARTIFACT_DIR/zsh-startup.json"
printf '1\t100\n2\t34\n' >"$ARTIFACT_DIR/install-timings.tsv"

PATH="$MOCK_BIN:$PATH" \
  E2E_PROFILE=developer \
  DOTFILES_WSL=true \
  GITHUB_RUN_ID=1234 \
  GITHUB_RUN_ATTEMPT=2 \
  GITHUB_SHA=abc123 \
  DOTFILES_ZSH_REPORT_BUDGET_MS=1 \
  DOTFILES_STARSHIP_BUDGET_MS=1 \
  DOTFILES_SECOND_PASS_BUDGET_MS=1 \
  "$DOTFILES_DIR/scripts/performance-report.sh" "$ARTIFACT_DIR" >/dev/null

jq -e '
  .report_only == true and
  .schema_version == 1 and
  .context.profile == "developer" and
  .context.platform == "wsl-simulated" and
  .context.run_id == "1234" and
  .context.run_attempt == "2" and
  .context.commit == "abc123" and
  .metrics.zsh_startup.status == "regression" and
  .metrics.starship_render.status == "regression" and
  .metrics.second_install_pass.status == "regression" and
  .metrics.second_install_pass.value_ms == 34
' "$ARTIFACT_DIR/performance.json" >/dev/null
grep -Fq 'These budgets are report-only and do not block merges.' \
  "$ARTIFACT_DIR/performance.md"
grep -Fq 'Profile: `developer` | Platform: `wsl-simulated` | Run: `1234`' \
  "$ARTIFACT_DIR/performance.md"

if PATH="$MOCK_BIN:$PATH" \
  DOTFILES_ZSH_REPORT_BUDGET_MS=1 \
  DOTFILES_STARSHIP_BUDGET_MS=1 \
  DOTFILES_SECOND_PASS_BUDGET_MS=1 \
  DOTFILES_PERFORMANCE_ENFORCE=1 \
  "$DOTFILES_DIR/scripts/performance-report.sh" "$ARTIFACT_DIR" >/dev/null; then
  printf 'Enforced performance regressions reported success\n' >&2
  exit 1
fi

printf 'Performance report test passed\n'
