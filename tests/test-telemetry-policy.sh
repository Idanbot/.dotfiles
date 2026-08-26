#!/usr/bin/env bash
# Verify privacy controls, config preservation, and the telemetry audit command.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
mkdir -p \
  "$HOME/.config/rtk" \
  "$HOME/.config/atuin" \
  "$HOME/.gemini/antigravity-cli" \
  "$HOME/.codex"

cp "$DOTFILES_DIR/dot_config/rtk/config.toml" "$HOME/.config/rtk/config.toml"
cp "$DOTFILES_DIR/dot_config/atuin/config.toml" "$HOME/.config/atuin/config.toml"
printf '{"model":"fixture","enableTelemetry":false}\n' \
  >"$HOME/.gemini/antigravity-cli/settings.json"
cat >"$HOME/.codex/config.toml" <<'EOF'
model = "fixture"

[analytics]
enabled = false

[otel]
exporter = "none"
trace_exporter = "none"
metrics_exporter = "none"
log_user_prompt = false
EOF

# shellcheck source=/dev/null
source "$DOTFILES_DIR/dot_config/dotfiles/privacy.sh"
output="$("$DOTFILES_DIR/dot_local/bin/executable_dot-privacy")"
grep -Fq '[PASS] RTK telemetry is disabled by environment and config' <<<"$output"
grep -Fq '[PASS] Claude Code telemetry, error reporting, and bug submission are disabled' <<<"$output"
grep -Fq '[PASS] Antigravity telemetry is disabled' <<<"$output"
grep -Fq '[PASS] Codex analytics and OpenTelemetry export are disabled' <<<"$output"
grep -Fq 'Summary: 0 failure(s), 0 warning(s)' <<<"$output"

printf '{"model":"preserved","enableTelemetry":true}\n' \
  >"$HOME/.gemini/antigravity-cli/settings.json"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"
set_json_boolean_preserving \
  "$HOME/.gemini/antigravity-cli/settings.json" enableTelemetry false
[[ "$(jq -r '.model' "$HOME/.gemini/antigravity-cli/settings.json")" == preserved ]]
[[ "$(jq -r '.enableTelemetry' "$HOME/.gemini/antigravity-cli/settings.json")" == false ]]
[[ "$(stat -c '%a' "$HOME/.gemini/antigravity-cli/settings.json")" == 600 ]]

printf '{broken json\n' >"$HOME/.gemini/antigravity-cli/settings.json"
before="$(sha256sum "$HOME/.gemini/antigravity-cli/settings.json")"
if set_json_boolean_preserving \
  "$HOME/.gemini/antigravity-cli/settings.json" enableTelemetry false; then
  printf 'invalid Antigravity settings were accepted\n' >&2
  exit 1
fi
[[ "$(sha256sum "$HOME/.gemini/antigravity-cli/settings.json")" == "$before" ]]

installer="$DOTFILES_DIR/.chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl"
grep -Fq 'set_json_boolean_preserving "$AGY_SETTINGS" enableTelemetry false' "$installer"
grep -Fq 'Antigravity telemetry disabled without replacing other settings' "$installer"

grep -Fq 'RTK_TELEMETRY_DISABLED=1' "$DOTFILES_DIR/dot_config/dotfiles/privacy.sh"
grep -Fq 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1' \
  "$DOTFILES_DIR/dot_config/dotfiles/privacy.sh"
grep -Fq 'analytics.enabled=false' "$DOTFILES_DIR/dot_local/bin/executable_dot-privacy"

# The lifecycle wrapper remains usable before a shell restart exposes the
# newly materialized ~/.local/bin entrypoint.
fallback_output="$(
  PATH=/usr/bin:/bin \
    DOTFILES_SOURCE_DIR="$DOTFILES_DIR" \
    "$DOTFILES_DIR/dot_local/bin/executable_dot" privacy
)"
grep -Fq 'Summary: 0 failure(s)' <<<"$fallback_output"

printf 'Telemetry policy test passed\n'
