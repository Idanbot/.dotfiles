#!/usr/bin/env bash
# Post-bootstrap acceptance checks for the selected installation contract.

set -euo pipefail

DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"

SECTIONS="detect,core,zsh,terminal,languages,history,cloud,tmux,neovim,ai,media,fonts,desktop,system,theme,vscode,services"
ACCEPTANCE=false
JSON_OUTPUT=false
QUICK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sections)
      SECTIONS="${2:-}"
      shift 2
      ;;
    --sections=*)
      SECTIONS="${1#*=}"
      shift
      ;;
    --acceptance)
      ACCEPTANCE=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --quick)
      QUICK=true
      shift
      ;;
    -h | --help)
      printf 'Usage: scripts/doctor.sh [--acceptance] [--sections a,b] [--json] [--quick]\n'
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

CHECKS=0
FAILURES=0
WARNINGS=0
RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

selected() { [[ ",$SECTIONS," == *",$1,"* ]]; }

result() {
  local state="$1" name="$2" detail="$3"
  ((CHECKS++)) || true
  printf '%s\t%s\t%s\n' "$state" "$name" "$detail" >>"$RESULTS"
  case "$state" in
    pass) printf '  %b[PASS]%b %s: %s\n' "$GREEN" "$NC" "$name" "$detail" ;;
    warn)
      printf '  %b[WARN]%b %s: %s\n' "$YELLOW" "$NC" "$name" "$detail"
      ((WARNINGS++)) || true
      ;;
    fail)
      printf '  %b[FAIL]%b %s: %s\n' "$RED" "$NC" "$name" "$detail"
      ((FAILURES++)) || true
      ;;
  esac
}

check_command() {
  local command="$1" required="${2:-true}" label="${3:-$1}"
  if command -v "$command" >/dev/null 2>&1; then
    result pass "$label" "$(command -v "$command")"
  elif [[ "$required" == true ]]; then
    result fail "$label" "command not found"
  else
    result warn "$label" "optional command not found"
  fi
}

check_file() {
  local path="$1" label="$2"
  [[ -e "$path" ]] && result pass "$label" "$path" || result fail "$label" "missing $path"
}

check_private_mode() {
  local path="$1" label="$2" mode
  [[ -e "$path" ]] || return 0
  mode="$(stat -c '%a' "$path")"
  if ((8#$mode & 8#077)); then
    result fail "$label" "mode $mode exposes local-only data"
  else
    result pass "$label" "mode $mode"
  fi
}

log_step "Platform"
if assert_supported_platform; then
  result pass platform "$(get_platform)"
else
  result fail platform "unsupported $(get_platform)"
fi
check_command chezmoi true

if selected core; then
  log_step "Core"
  for command in git curl wget jq yq make unzip rg fdfind batcat btop zoxide direnv delta hyperfine duf; do
    check_command "$command" true
  done
fi

if selected zsh; then
  log_step "Shell"
  check_command zsh true
  check_file "$HOME/.zshrc" zsh-config
  check_file "$HOME/.oh-my-zsh/oh-my-zsh.sh" oh-my-zsh
  if [[ "$QUICK" == false ]] && command -v timeout >/dev/null 2>&1; then
    if timeout 8 zsh -dfi -c 'source ~/.zshrc; command -v node >/dev/null 2>&1 || true; exit' </dev/null >/dev/null 2>&1; then
      result pass zsh-startup "interactive config loaded"
    else
      result fail zsh-startup "interactive config failed or exceeded 8s"
    fi
  fi
fi

if selected terminal; then
  log_step "Terminal"
  for command in fzf fd bat eza lazygit starship sops lazydocker tldr; do
    check_command "$command" true
  done
fi

if selected languages; then
  log_step "Languages"
  for command in go rustc cargo node npm tsc uv uvx java; do
    check_command "$command" true
  done
  if command -v node >/dev/null 2>&1 && [[ "$(command -v node)" == "$HOME/.local/bin/node" ]]; then
    result pass node-shim "stable user-local path"
  else
    result fail node-shim "expected $HOME/.local/bin/node, found $(command -v node 2>/dev/null || printf missing)"
  fi
fi

if selected history; then
  log_step "History"
  check_command atuin true
fi

if selected cloud; then
  log_step "Cloud"
  for command in docker kubectl helm terraform ansible k9s aws gcloud az; do
    check_command "$command" true
  done
fi

if selected tmux; then
  log_step "Tmux"
  check_command tmux true
  check_file "$HOME/.tmux.conf" tmux-config
  check_file "$HOME/.config/tmuxp/agent-workspace.yaml" agent-workspace
  check_command dot-workspace true
  if [[ "$QUICK" == false ]] && tmux -L dotfiles-doctor -f "$HOME/.tmux.conf" start-server 2>/dev/null; then
    tmux -L dotfiles-doctor kill-server 2>/dev/null || true
    result pass tmux-config "server accepted configuration"
  elif [[ "$QUICK" == false ]]; then
    result fail tmux-config "tmux rejected configuration"
  fi
fi

if selected neovim; then
  log_step "Neovim"
  check_command nvim true
  check_file "$HOME/.config/nvim/lazy-lock.json" neovim-lock
  if "$DOTFILES_SOURCE_DIR/scripts/validate-neovim.sh" --quick >/dev/null 2>&1; then
    result pass neovim-runtime "clean headless validation passed"
  else
    result fail neovim-runtime "headless validation failed"
  fi
fi

if selected ai; then
  log_step "Agent CLIs"
  for command in claude codex gemini opencode omp; do
    check_command "$command" true
  done
  check_command antigravity false
  result warn agent-auth "authentication is intentionally manual"
fi

if selected media && is_native; then
  log_step "Media"
  for command in yt-dlp rmpc cava; do check_command "$command" true; done
fi
if selected fonts; then
  log_step "Fonts"
  fc-list 2>/dev/null | grep -qi 'FiraMono Nerd' && result pass nerd-font "FiraMono detected" || result fail nerd-font "FiraMono Nerd Font missing"
fi
if selected desktop && is_native; then
  log_step "Desktop"
  check_command kitty true
fi
if selected system; then
  log_step "System"
  check_command git-credential-manager true
fi
if selected theme; then
  log_step "Themes"
  check_file "$HOME/.config/btop/themes/catppuccin_mocha.theme" btop-theme
fi

log_step "State & Security"
STATE_ROOT="$(managed_state_root)"
check_private_mode "$STATE_ROOT/installed.tsv" install-ledger
for local_file in \
  "$HOME/.config/dotfiles/local.zsh" \
  "$HOME/.config/dotfiles/local.tmux.conf" \
  "$HOME/.config/dotfiles/machine.conf" \
  "$HOME/.config/git/config.local" \
  "$HOME/.ssh/config.local"; do
  check_private_mode "$local_file" "local-$(basename "$local_file")"
done
if find "$DOTFILES_SOURCE_DIR" -maxdepth 2 -type f \( -name 'encrypted_*' -o -name 'key.txt' \) | grep -q .; then
  result fail secret-boundary "encrypted payload or age identity found in public source"
else
  result pass secret-boundary "public source is credential-free"
fi

printf '\n%b-- Doctor Summary --%b\n' "$BOLD" "$NC"
printf '  Checks: %s  Warnings: %s  Failures: %s\n' "$CHECKS" "$WARNINGS" "$FAILURES"

if [[ "$JSON_OUTPUT" == true ]]; then
  python3 - "$RESULTS" "$CHECKS" "$WARNINGS" "$FAILURES" <<'PY'
import json
import sys

path, checks, warnings, failures = sys.argv[1:]
results = []
with open(path, encoding="utf-8") as handle:
    for line in handle:
        state, name, detail = line.rstrip("\n").split("\t", 2)
        results.append({"state": state, "name": name, "detail": detail})
print(json.dumps({
    "checks": int(checks),
    "warnings": int(warnings),
    "failures": int(failures),
    "results": results,
}, indent=2))
PY
fi

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
if [[ "$ACCEPTANCE" == true ]]; then
  log_success "Selected installation contract is healthy"
fi
