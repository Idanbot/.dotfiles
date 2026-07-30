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
STRICT=false
VALID_SECTIONS="detect,core,zsh,terminal,languages,history,cloud,tmux,neovim,ai,media,fonts,desktop,system,theme,vscode,services"

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
    --strict)
      STRICT=true
      shift
      ;;
    -h | --help)
      printf 'Usage: scripts/doctor.sh [--acceptance] [--sections a,b] [--json] [--quick] [--strict]\n'
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$SECTIONS" ]]; then
  printf 'At least one section is required\n' >&2
  exit 2
fi
IFS=',' read -r -a REQUESTED_SECTIONS <<<"$SECTIONS"
for section in "${REQUESTED_SECTIONS[@]}"; do
  if [[ -z "$section" || ",$VALID_SECTIONS," != *",$section,"* ]]; then
    printf 'Unknown section: %s\nValid sections: %s\n' "${section:-<empty>}" "$VALID_SECTIONS" >&2
    exit 2
  fi
done

CHECKS=0
FAILURES=0
WARNINGS=0
RESULTS="$(mktemp)"
TMUX_CHECK_CONFIG=""
cleanup() {
  rm -f "$RESULTS"
  [[ -z "$TMUX_CHECK_CONFIG" ]] || rm -f "$TMUX_CHECK_CONFIG"
}
trap cleanup EXIT

selected() { [[ ",$SECTIONS," == *",$1,"* ]]; }

doctor_step() {
  [[ "$JSON_OUTPUT" == true ]] || log_step "$1"
}

result() {
  local state="$1" name="$2" detail="$3" remedy="${4:-}"
  ((CHECKS++)) || true
  detail="${detail//$'\t'/ }"
  detail="${detail//$'\n'/ }"
  remedy="${remedy//$'\t'/ }"
  remedy="${remedy//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\n' "$state" "$name" "$detail" "$remedy" >>"$RESULTS"
  if [[ "$JSON_OUTPUT" == true ]]; then
    case "$state" in
      warn) ((WARNINGS++)) || true ;;
      fail) ((FAILURES++)) || true ;;
    esac
    return
  fi
  case "$state" in
    pass) printf '  %b[PASS]%b %s: %s\n' "$GREEN" "$NC" "$name" "$detail" ;;
    warn)
      printf '  %b[WARN]%b %s: %s\n' "$YELLOW" "$NC" "$name" "$detail"
      [[ -z "$remedy" ]] || printf '         Fix: %s\n' "$remedy"
      ((WARNINGS++)) || true
      ;;
    fail)
      printf '  %b[FAIL]%b %s: %s\n' "$RED" "$NC" "$name" "$detail"
      [[ -z "$remedy" ]] || printf '         Fix: %s\n' "$remedy"
      ((FAILURES++)) || true
      ;;
  esac
}

check_command() {
  local command="$1" required="${2:-true}" label="${3:-$1}"
  if command -v "$command" >/dev/null 2>&1; then
    result pass "$label" "$(command -v "$command")"
  elif [[ "$required" == true ]]; then
    result fail "$label" "command not found" "rerun the section that owns $label"
  else
    result warn "$label" "optional command not found"
  fi
}

check_stable_command() {
  local command="$1" expected="$HOME/.local/bin/$1" actual
  actual="$(command -v "$command" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    result pass "$command-shim" "$expected"
  elif [[ -n "$actual" ]]; then
    result warn "$command-shim" "resolved to $actual, expected stable path $expected" \
      "rerun the languages section to recreate the user-local shim"
  else
    result fail "$command-shim" "command not found" "rerun the languages section"
  fi
}

check_file() {
  local path="$1" label="$2"
  [[ -e "$path" ]] && result pass "$label" "$path" ||
    result fail "$label" "missing $path" "rerun the section that manages $label"
}

check_instruction_link() {
  local path="$1" label="$2" canonical="$HOME/.config/agents/AGENTS.md"
  if [[ -f "$canonical" && -L "$path" ]] &&
    [[ "$(readlink -f "$path")" == "$(readlink -f "$canonical")" ]]; then
    result pass "$label" "$path -> $canonical"
  else
    result fail "$label" "$path does not resolve to $canonical" \
      "rerun chezmoi apply to restore shared agent instructions"
  fi
}

check_ledger() {
  local ledger="$1" malformed duplicates
  [[ -f "$ledger" ]] || {
    result warn install-ledger "not created yet" "run a managed installation"
    return
  }
  malformed="$(awk -F '\t' 'NF != 6 || $1 == "" || $3 == "" || $4 == "" { count++ } END { print count + 0 }' "$ledger")"
  duplicates="$(awk -F '\t' '{ key = $1 FS $4; seen[key]++ } END { for (key in seen) if (seen[key] > 1) count++; print count + 0 }' "$ledger")"
  if ((malformed > 0)); then
    result fail install-ledger "$malformed malformed row(s) in $ledger" \
      "inspect the ledger and rerun the owning install sections"
  elif ((duplicates > 0)); then
    result warn install-ledger "$duplicates duplicate tool/target row(s)" \
      "rerun the owning install sections to reconcile the ledger"
  else
    result pass install-ledger "$(wc -l <"$ledger") valid entries"
  fi
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

doctor_step "Platform"
if assert_supported_platform; then
  result pass platform "$(get_platform)"
else
  result fail platform "unsupported $(get_platform)" "use native Ubuntu or WSL Ubuntu"
fi
check_command chezmoi true

if selected core; then
  doctor_step "Core"
  for command in git curl wget jq yq make unzip rg fdfind batcat btop zoxide direnv delta hyperfine duf; do
    check_command "$command" true
  done
fi

if selected zsh; then
  doctor_step "Shell"
  check_command zsh true
  check_file "$HOME/.zshrc" zsh-config
  check_file "$HOME/.oh-my-zsh/oh-my-zsh.sh" oh-my-zsh
  if [[ "$QUICK" == false ]] && command -v timeout >/dev/null 2>&1; then
    if timeout 8 zsh -dfi -c 'source ~/.zshrc; command -v node >/dev/null 2>&1 || true; exit' </dev/null >/dev/null 2>&1; then
      result pass zsh-startup "interactive config loaded"
    else
      result fail zsh-startup "interactive config failed or exceeded 8s" \
        "run: timeout 8 zsh -dfixc 'source ~/.zshrc'"
    fi
  fi
fi

if selected terminal; then
  doctor_step "Terminal"
  for command in fzf fd bat eza lazygit starship sops lazydocker tldr curlie gojq pigz zstd; do
    check_command "$command" true
  done
fi

if selected languages; then
  doctor_step "Languages"
  for command in go rustc cargo node npm tsc uv uvx java; do
    check_command "$command" true
  done
  for command in go rustc cargo node npm tsc; do
    check_stable_command "$command"
  done
fi

if selected history; then
  doctor_step "History"
  check_command atuin true
fi

if selected cloud; then
  doctor_step "Cloud"
  for command in \
    docker kubectl helm terraform ansible k9s aws gcloud az cloud-context \
    s5cmd kcat stern helmfile kubectx kubens pgloader cloudflare-ssh; do
    check_command "$command" true
  done
fi

if selected tmux; then
  doctor_step "Terminal Multiplexers"
  check_command tmux true
  check_command herdr true
  check_file "$HOME/.tmux.conf" tmux-config
  check_file "$HOME/.config/tmuxp/agent-workspace.yaml" agent-workspace
  check_file "$HOME/.config/herdr/config.toml" herdr-config
  check_file "$HOME/.config/dotfiles/agents.yaml" agent-registry
  check_command dot-workspace true
  check_command dot-agent-launch true
  if [[ "$QUICK" == false ]]; then
    TMUX_CHECK_CONFIG="$(mktemp)"
    # Killing a probe server while TPM runs asynchronously can orphan plugin
    # processes that recursively restart tmux. The probe only needs syntax.
    sed '\|^[[:space:]]*run[[:space:]]\+-b.*tpm/tpm|d' \
      "$HOME/.tmux.conf" >"$TMUX_CHECK_CONFIG"
  fi
  if [[ "$QUICK" == false ]] &&
    tmux -L dotfiles-doctor -f "$TMUX_CHECK_CONFIG" start-server 2>/dev/null; then
    tmux -L dotfiles-doctor kill-server 2>/dev/null || true
    result pass tmux-config "server accepted configuration"
  elif [[ "$QUICK" == false ]]; then
    result fail tmux-config "tmux rejected configuration" \
      "run: tmux -L dotfiles-debug -f ~/.tmux.conf start-server"
  fi
  if command -v herdr >/dev/null 2>&1 && [[ "$(herdr --version 2>/dev/null)" == herdr* ]]; then
    result pass herdr-runtime "binary and managed configuration available"
    if herdr integration status >/dev/null 2>&1; then
      result pass herdr-integrations "integration status is readable"
    else
      result warn herdr-integrations "run herdr integration status"
    fi
  else
    result fail herdr-runtime "Herdr version check failed"
  fi
fi

if selected neovim; then
  doctor_step "Neovim"
  check_command nvim true
  check_file "$HOME/.config/nvim/lazy-lock.json" neovim-lock
  if "$DOTFILES_SOURCE_DIR/scripts/validate-neovim.sh" --quick >/dev/null 2>&1; then
    result pass neovim-runtime "clean headless validation passed"
  else
    result fail neovim-runtime "headless validation failed" \
      "run scripts/validate-neovim.sh --quick without output redirection"
  fi
fi

if selected ai; then
  doctor_step "Agent CLIs"
  for command in claude codex agy opencode omp serena context-mode agent-mcp; do
    check_command "$command" true
  done
  check_file "$HOME/.config/agents/AGENTS.md" agent-instructions
  check_instruction_link "$HOME/.codex/AGENTS.md" codex-instructions
  check_instruction_link "$HOME/.claude/CLAUDE.md" claude-instructions
  check_instruction_link "$HOME/.gemini/GEMINI.md" antigravity-instructions
  check_instruction_link "$HOME/.config/opencode/AGENTS.md" opencode-instructions
  check_instruction_link "$HOME/.omp/agent/AGENTS.md" omp-instructions
  result warn agent-auth "authentication is intentionally manual"
fi

if selected media && is_native; then
  doctor_step "Media"
  for command in yt-dlp rmpc cava; do check_command "$command" true; done
fi
if selected fonts; then
  doctor_step "Fonts"
  FONT_NAME="$(package_version fonts nerd_font FiraMono)"
  FONT_DIR="$HOME/.local/share/fonts/$FONT_NAME"
  if nerd_font_registered "$FONT_NAME"; then
    result pass nerd-font "$FONT_NAME detected by fontconfig"
  elif nerd_font_files_present "$FONT_NAME" "$FONT_DIR"; then
    result pass nerd-font "$FONT_NAME files installed at $FONT_DIR"
  else
    result fail nerd-font "$FONT_NAME Nerd Font missing" \
      "rerun: $DOTFILES_SOURCE_DIR/scripts/run-section.sh fonts"
  fi
fi
if selected desktop && is_native; then
  doctor_step "Desktop"
  check_command kitty true
fi
if selected system; then
  doctor_step "System"
  check_command git-credential-manager true
  check_command ssh-key-load true
  check_file "$HOME/.ssh/config" ssh-config
fi
if selected theme; then
  doctor_step "Themes"
  check_file "$HOME/.config/btop/themes/catppuccin_mocha.theme" btop-theme
fi

doctor_step "Source, State & Security"
STATE_ROOT="$(managed_state_root)"
if [[ -e "$DOTFILES_SOURCE_DIR/.git" && -r "$DOTFILES_SOURCE_DIR/packages.yaml" ]]; then
  result pass source-integrity "$DOTFILES_SOURCE_DIR"
else
  result fail source-integrity "source is incomplete at $DOTFILES_SOURCE_DIR" \
    "repair with: dot sync --profile base"
fi
if ensure_private_directory "$STATE_ROOT" 2>/dev/null && [[ -w "$STATE_ROOT" ]]; then
  result pass state-directory "$STATE_ROOT is writable"
else
  result fail state-directory "$STATE_ROOT is not writable" \
    "restore ownership with: sudo chown -R \"$USER\":\"$USER\" \"$STATE_ROOT\""
fi
check_private_mode "$STATE_ROOT" state-directory-mode
check_ledger "$STATE_ROOT/installed.tsv"
check_private_mode "$STATE_ROOT/installed.tsv" install-ledger-mode
for local_file in \
  "$HOME/.config/dotfiles/local.zsh" \
  "$HOME/.config/dotfiles/local.tmux.conf" \
  "$HOME/.config/dotfiles/machine.conf" \
  "$HOME/.config/git/config.local" \
  "$HOME/.ssh/config.local"; do
  check_private_mode "$local_file" "local-$(basename "$local_file")"
done
if find "$DOTFILES_SOURCE_DIR" -maxdepth 2 -type f \( -name 'encrypted_*' -o -name 'key.txt' \) | grep -q .; then
  result fail secret-boundary "encrypted payload or age identity found in public source" \
    "remove identities and encrypted payloads from the public repository"
else
  result pass secret-boundary "public source is credential-free"
fi

if [[ "$JSON_OUTPUT" == false ]]; then
  printf '\n%b-- Doctor Summary --%b\n' "$BOLD" "$NC"
  printf '  Checks: %s  Warnings: %s  Failures: %s\n' "$CHECKS" "$WARNINGS" "$FAILURES"
fi

if [[ "$JSON_OUTPUT" == true ]]; then
  python3 - "$RESULTS" "$CHECKS" "$WARNINGS" "$FAILURES" \
    "$(get_platform)" "$DOTFILES_SOURCE_DIR" "$SECTIONS" <<'PY'
import json
import sys

path, checks, warnings, failures, platform, source, sections = sys.argv[1:]
results = []
with open(path, encoding="utf-8") as handle:
    for line in handle:
        state, name, detail, remedy = line.rstrip("\n").split("\t", 3)
        item = {"state": state, "name": name, "detail": detail}
        if remedy:
            item["remedy"] = remedy
        results.append(item)
print(json.dumps({
    "schema_version": 1,
    "healthy": int(failures) == 0,
    "platform": platform,
    "source": source,
    "sections": sections.split(","),
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
if [[ "$STRICT" == true && "$WARNINGS" -gt 0 ]]; then
  exit 1
fi
if [[ "$ACCEPTANCE" == true ]]; then
  [[ "$JSON_OUTPUT" == true ]] || log_success "Selected installation contract is healthy"
fi
