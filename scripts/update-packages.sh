#!/usr/bin/env bash
# Discover upstream versions and safely update checksum-verifiable pins.

set -euo pipefail

DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"

MODE=check
case "${1:-}" in
  --apply) MODE=apply ;;
  --check | '') MODE=check ;;
  -h | --help)
    printf 'Usage: scripts/update-packages.sh [--check|--apply]\n'
    exit 0
    ;;
  *)
    printf 'Unknown option: %s\n' "$1" >&2
    exit 2
    ;;
esac

PACKAGES_FILE="$DOTFILES_SOURCE_DIR/packages.yaml"
REPORT="${DOTFILES_UPDATE_REPORT:-$DOTFILES_SOURCE_DIR/.version-update-report}"
UPDATES=0
APPLIED=0
MANUAL=0
printf 'Version audit %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$REPORT"

github_release() {
  github_latest_release "$1" | sed 's/^v//'
}

npm_release() {
  curl --proto '=https' --tlsv1.2 --retry 3 -fsSL \
    "https://registry.npmjs.org/$1/latest" | jq -r .version
}

pypi_release() {
  curl --proto '=https' --tlsv1.2 --retry 3 -fsSL \
    "https://pypi.org/pypi/$1/json" | jq -r .info.version
}

set_manifest_version() {
  local section="$1" key="$2" version="$3"
  python3 - "$PACKAGES_FILE" "$section" "$key" "$version" <<'PY'
import re
import sys
from pathlib import Path

path, section, key, version = sys.argv[1:]
lines = Path(path).read_text(encoding="utf-8").splitlines()
inside = False
changed = False
for index, line in enumerate(lines):
    if re.fullmatch(rf"{re.escape(section)}:\s*", line):
        inside = True
        continue
    if inside and line and not line.startswith((" ", "#")):
        inside = False
    if inside and re.match(rf"  {re.escape(key)}:\s*", line):
        comment = ""
        if " #" in line:
            comment = " #" + line.split(" #", 1)[1]
        lines[index] = f'  {key}: "{version}"{comment}'
        changed = True
        break
if not changed:
    raise SystemExit(f"manifest key not found: {section}.{key}")
Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

audit() {
  local section="$1" key="$2" latest="$3" policy="$4" current
  current="$(package_version "$section" "$key")"
  latest="${latest#v}"
  [[ -n "$latest" && "$latest" != null ]] || {
    log_warn "Could not resolve $section.$key"
    return 0
  }
  if version_equals "$current" "$latest" || version_ge "$current" "$latest"; then
    log_skip "$section.$key $current"
    return 0
  fi

  ((UPDATES++)) || true
  printf '%s.%s %s -> %s (%s)\n' "$section" "$key" "$current" "$latest" "$policy" | tee -a "$REPORT"
  if [[ "$policy" == manual-integrity ]]; then
    ((MANUAL++)) || true
    return 0
  fi
  if [[ "$MODE" == apply ]]; then
    set_manifest_version "$section" "$key" "$latest"
    ((APPLIED++)) || true
  fi
}

audit bootstrap chezmoi "$(github_release twpayne/chezmoi)" auto
audit core fzf "$(github_release junegunn/fzf)" external
audit core eza "$(github_release eza-community/eza)" auto
audit core lazygit "$(github_release jesseduffield/lazygit)" auto
audit core starship "$(github_release starship/starship)" auto
audit core sops "$(github_release getsops/sops)" auto
audit core lazydocker "$(github_release jesseduffield/lazydocker)" auto
audit core tealdeer "$(github_release dbrgn/tealdeer)" auto
audit languages go "$(curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r '.[0].version' | sed 's/^go//')" auto
audit languages node_lts "$(curl -fsSL https://nodejs.org/dist/index.json | jq -r 'map(select(.lts != false))[0].version' | sed 's/^v//')" auto
audit languages typescript "$(npm_release typescript)" auto
audit languages uv "$(github_release astral-sh/uv)" auto
audit history atuin "$(github_release atuinsh/atuin)" auto
audit editor neovim "$(github_release neovim/neovim)" manual-integrity
audit cloud kubectl "$(curl -fsSL https://dl.k8s.io/release/stable.txt | sed 's/^v//')" auto
audit cloud helm "$(github_release helm/helm)" auto
audit cloud terraform "$(github_release hashicorp/terraform)" auto
audit cloud k9s "$(github_release derailed/k9s)" auto
audit system git_credential_manager "$(github_release git-ecosystem/git-credential-manager)" manual-integrity
audit fonts nerd_font_version "$(github_release ryanoasis/nerd-fonts)" auto
audit ai_tools claude_cli "$(npm_release @anthropic-ai/claude-code)" auto
audit ai_tools gemini_cli "$(npm_release @google/gemini-cli)" auto
audit ai_tools opencode "$(npm_release opencode-ai)" auto
audit ai_tools omp "$(npm_release @oh-my-pi/pi-coding-agent)" auto
audit terminal tmuxp "$(pypi_release tmuxp)" auto
audit media yt_dlp "$(github_release yt-dlp/yt-dlp)" auto
audit media rmpc "$(github_release mierak/rmpc)" manual-integrity

if [[ "$MODE" == apply && "$APPLIED" -gt 0 ]]; then
  "$DOTFILES_SOURCE_DIR/scripts/generate-package-lock.sh"
  "$DOTFILES_SOURCE_DIR/scripts/generate-tool-inventory.sh"
fi

log_info "Updates: $UPDATES; applied: $APPLIED; manual integrity refreshes: $MANUAL"
if [[ "$MODE" == check && "$UPDATES" -gt 0 ]]; then
  exit 3
fi
