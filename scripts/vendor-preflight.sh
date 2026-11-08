#!/usr/bin/env bash
# Verify only standalone installers that the AI section will execute.
set -euo pipefail
DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
for tool in codex_cli antigravity_cli; do
  command_name=agy
  [[ "$tool" != codex_cli ]] || command_name=codex
  active="$(command -v "$command_name" || true)"
  if [[ -n "$active" && ("$tool" != codex_cli || "$active" != "$HOME/.nvm/"*) ]]; then
    continue
  fi
  log_info "Preflight: verifying $command_name installer (without execution)"
  if ! download_vendor_installer "$tool" "$temporary/$tool.sh"; then
    log_error "$command_name installer unavailable or changed; review scripts/update-packages.sh --apply ai_tools.$tool before retrying"
    exit 1
  fi
done
