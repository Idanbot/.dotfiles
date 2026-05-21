#!/usr/bin/env bash
# uninstall-tool.sh — Best-effort rollback helper for dotfiles-installed tools
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/uninstall-tool.sh <tool>

Removes tools installed by these dotfiles from common local destinations.
Currently supports /usr/local/bin binaries, ~/.local/bin shims, and cargo binaries.
USAGE
}

if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

tool="$1"
removed=0

remove_path() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    rm -f "$path"
    echo "removed $path"
    removed=1
  fi
}

case "$tool" in
  lazygit|lazydocker|sops|tldr|k9s|rmpc|yt-dlp|nvim)
    if [[ -w /usr/local/bin ]]; then
      remove_path "/usr/local/bin/$tool"
    else
      sudo rm -f "/usr/local/bin/$tool"
      echo "removed /usr/local/bin/$tool"
      removed=1
    fi
    ;;
  fd|bat)
    remove_path "$HOME/.local/bin/$tool"
    ;;
  dust)
    if command -v cargo >/dev/null 2>&1; then
      cargo uninstall du-dust || true
      removed=1
    fi
    remove_path "$HOME/.cargo/bin/dust"
    ;;
  xh)
    if command -v cargo >/dev/null 2>&1; then
      cargo uninstall xh || true
      removed=1
    fi
    remove_path "$HOME/.cargo/bin/xh"
    ;;
  *)
    echo "No uninstall rule for $tool" >&2
    exit 2
    ;;
esac

if [[ "$removed" -eq 0 ]]; then
  echo "$tool was not installed in a managed location"
fi
