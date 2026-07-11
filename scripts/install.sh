#!/usr/bin/env bash
# Reliable bootstrap for Ubuntu 24.04, native or WSL.
# shellcheck disable=SC2317

set -Eeuo pipefail

DOTFILES_REPO_URL="${DOTFILES_REPO_URL:-https://github.com/Idanbot/.dotfiles.git}"
DOTFILES_COLOR="${DOTFILES_COLOR:-auto}"
DOTFILES_LOG="${DOTFILES_LOG:-1}"
DOTFILES_LOG_RETENTION="${DOTFILES_LOG_RETENTION:-20}"
DOTFILES_CONFLICT_POLICY="${DOTFILES_CONFLICT_POLICY:-backup}"
DOTFILES_ROLLBACK_ON_ERROR="${DOTFILES_ROLLBACK_ON_ERROR:-1}"

SCRIPT_DIR=""
LOCAL_SOURCE="${DOTFILES_SOURCE_OVERRIDE:-}"
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [[ -z "$LOCAL_SOURCE" && -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/../.chezmoi.yaml.tmpl" ]]; then
    LOCAL_SOURCE="$(cd "$SCRIPT_DIR/.." && pwd)"
  fi
fi

SECTION_ORDER=(
  detect core zsh terminal languages history cloud tmux neovim ai media fonts
  desktop system theme vscode services
)
declare -A BUILTIN_PROFILES=(
  [minimal]="detect,core"
  [base]="detect,core,zsh,terminal"
  [developer]="detect,core,zsh,terminal,languages,history,tmux,neovim,system,theme,services"
  [agent]="detect,core,zsh,terminal,languages,history,tmux,neovim,ai,system,theme,services"
  [cloud]="detect,core,zsh,terminal,languages,history,cloud,tmux,neovim,system,theme,services"
  [full]="detect,core,zsh,terminal,languages,history,cloud,tmux,neovim,ai,media,fonts,desktop,system,theme,vscode,services"
)
declare -A PROFILE_SECTION_DEPENDENCIES=(
  [tmux]=languages
  [ai]=languages
  [media]=languages
)

SELECTED_SECTIONS=()
WITH_SECTIONS=()
WITHOUT_SECTIONS=()
SELECTION_MODE=""
PROFILE_NAME=""
AUTO_APPROVE=false
PRINT_PLAN=false
LIST_OPTIONS=false
MENU_REQUESTED=false
ONLY_SECTION=""
SOURCE_OVERRIDE=""
RESUME_REQUEST=""
RUN_DOCTOR=true
CHEZMOI_SOURCE=""
CHEZMOI_STATUS_OUTPUT=""
BACKUP_ID=""
CURRENT_STAGE="startup"
RUN_STARTED_EPOCH="$(date +%s)"
_HANDLING_ERROR=false

join_by_comma() {
  local IFS=,
  printf '%s\n' "$*"
}

terminal_color_enabled() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]] || return 1
  case "$DOTFILES_COLOR" in
    always) return 0 ;;
    never) return 1 ;;
    auto) [[ -t 1 || -n "${WT_SESSION:-}" ]] ;;
    *)
      printf 'Invalid DOTFILES_COLOR value: %s\n' "$DOTFILES_COLOR" >&2
      return 2
      ;;
  esac
}

if terminal_color_enabled; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
  BOLD=""
  DIM=""
  NC=""
fi
if [[ -n "$NC" ]]; then
  DOTFILES_COLOR_ACTIVE=true
else
  DOTFILES_COLOR_ACTIVE=false
fi
export DOTFILES_COLOR_ACTIVE

timestamp() { date '+%H:%M:%S'; }
log_info() { printf '%s %b[INFO]%b  %s\n' "$(timestamp)" "$BLUE" "$NC" "$*"; }
log_success() { printf '%s %b[OK]%b    %s\n' "$(timestamp)" "$GREEN" "$NC" "$*"; }
log_warn() { printf '%s %b[WARN]%b  %s\n' "$(timestamp)" "$YELLOW" "$NC" "$*"; }
log_error() { printf '%s %b[ERROR]%b %s\n' "$(timestamp)" "$RED" "$NC" "$*" >&2; }
log_skip() { printf '%s %b[SKIP]%b  %s\n' "$(timestamp)" "$DIM" "$NC" "$*"; }
log_step() { printf '\n%b== %s ==%b\n' "$BOLD$CYAN" "$*" "$NC"; }
log_banner() {
  printf '%b%s%b\n' "$BOLD$CYAN" '==============================================' "$NC"
  printf '%b  %s%b\n' "$BOLD$CYAN" "$*" "$NC"
  printf '%b%s%b\n' "$BOLD$CYAN" '==============================================' "$NC"
}

usage() {
  cat <<'USAGE'
Usage: scripts/install.sh [options]

Profiles and selectors:
  --profile <name>          minimal, base, developer, agent, cloud, or full
  --full                    Alias for --profile full
  --base-only               Alias for --profile base
  --with <a,b>              Base plus selected optional sections
  --sections <a,b>          Exactly these sections
  --without <a,b>           Remove sections from the selected profile
  --menu                    Force the interactive selector
  -y, --yes                 Accept defaults and never prompt

Reliability:
  --resume[=<run-id>]       Resume the latest or named interrupted run
  --conflict-policy <mode>  backup (default), skip, or abort
  --source <path>           Use a local source checkout
  --only <section>          Run one section from a local checkout
  --no-doctor               Skip the final acceptance check

Inspection:
  --list-options            Print profiles and sections
  --print-plan              Resolve the selection without installing
  -h, --help                Show this help

Examples:
  scripts/install.sh --profile developer -y
  scripts/install.sh --with languages,tmux,neovim -y
  scripts/install.sh --resume
  curl -fsSL https://raw.githubusercontent.com/Idanbot/.dotfiles/main/scripts/install.sh | \
    bash -s -- --profile base -y
USAGE
}

contains_section() {
  local needle="$1" section
  for section in "${SECTION_ORDER[@]}"; do
    [[ "$section" == "$needle" ]] && return 0
  done
  return 1
}

array_has() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

parse_csv_sections() {
  local value="$1"
  local -n output="$2"
  local raw=() section
  IFS=',' read -ra raw <<<"$value"
  for section in "${raw[@]}"; do
    section="${section//[[:space:]]/}"
    [[ -z "$section" ]] && continue
    if ! contains_section "$section"; then
      printf 'Unknown section: %s\n' "$section" >&2
      exit 2
    fi
    output+=("$section")
  done
}

profile_sections() {
  local profile="$1" source_root="${2:-$LOCAL_SOURCE}" file line key value
  file="$source_root/profiles/$profile.conf"
  if [[ -n "$source_root" && -f "$file" ]]; then
    while IFS='=' read -r key value; do
      [[ "$key" == sections ]] && {
        printf '%s\n' "$value"
        return 0
      }
    done <"$file"
  fi
  [[ -n "${BUILTIN_PROFILES[$profile]:-}" ]] || return 1
  printf '%s\n' "${BUILTIN_PROFILES[$profile]}"
}

select_profile() {
  local profile="$1" sections
  sections="$(profile_sections "$profile")" || {
    printf 'Unknown profile: %s\n' "$profile" >&2
    exit 2
  }
  SELECTED_SECTIONS=()
  parse_csv_sections "$sections" SELECTED_SECTIONS
  PROFILE_NAME="$profile"
  SELECTION_MODE="profile"
}

read_user() {
  local prompt="$1" destination="$2" value
  if [[ -t 0 ]]; then
    read -r -p "$prompt" value
  elif [[ -t 1 && -r /dev/tty ]]; then
    read -r -p "$prompt" value </dev/tty
  else
    read -r -p "$prompt" value
  fi
  printf -v "$destination" '%s' "$value"
}

show_menu() {
  local choice extras
  log_banner "Install Profile"
  printf '  1. Full        All supported sections\n'
  printf '  2. Minimal     Environment detection and essential packages\n'
  printf '  3. Base        Shell and terminal baseline\n'
  printf '  4. Developer   Languages, tmux, Neovim, and system setup\n'
  printf '  5. Agent       Developer plus AI coding harnesses\n'
  printf '  6. Cloud       Developer plus containers and cloud CLIs\n'
  printf '  7. Custom      Exact comma-separated section list\n\n'
  read_user 'Choose install profile [1]: ' choice
  case "${choice:-1}" in
    1) select_profile full ;;
    2) select_profile minimal ;;
    3) select_profile base ;;
    4) select_profile developer ;;
    5) select_profile agent ;;
    6) select_profile cloud ;;
    7)
      printf 'Sections: %s\n' "$(join_by_comma "${SECTION_ORDER[@]}")"
      read_user 'Sections: ' extras
      SELECTED_SECTIONS=()
      parse_csv_sections "$extras" SELECTED_SECTIONS
      PROFILE_NAME=custom
      SELECTION_MODE=custom
      ;;
    *)
      printf 'Unknown menu choice: %s\n' "$choice" >&2
      exit 2
      ;;
  esac
}

apply_selection_modifiers() {
  local section filtered=()
  for section in "${WITH_SECTIONS[@]}"; do
    array_has "$section" "${SELECTED_SECTIONS[@]}" || SELECTED_SECTIONS+=("$section")
  done
  for section in "${SELECTED_SECTIONS[@]}"; do
    array_has "$section" "${WITHOUT_SECTIONS[@]}" || filtered+=("$section")
  done
  SELECTED_SECTIONS=("${filtered[@]}")

  filtered=()
  for section in "${SECTION_ORDER[@]}"; do
    array_has "$section" "${SELECTED_SECTIONS[@]}" && filtered+=("$section")
  done
  SELECTED_SECTIONS=("${filtered[@]}")
}

resolve_profile_dependencies() {
  local section dependency filtered=()
  [[ "$SELECTION_MODE" == profile ]] || return 0

  for section in "${SELECTED_SECTIONS[@]}"; do
    dependency="${PROFILE_SECTION_DEPENDENCIES[$section]:-}"
    [[ -n "$dependency" ]] || continue
    if array_has "$dependency" "${WITHOUT_SECTIONS[@]}"; then
      printf "Section '%s' requires '%s', but '%s' was explicitly excluded\n" \
        "$section" "$dependency" "$dependency" >&2
      exit 2
    fi
    array_has "$dependency" "${SELECTED_SECTIONS[@]}" || SELECTED_SECTIONS+=("$dependency")
  done

  for section in "${SECTION_ORDER[@]}"; do
    array_has "$section" "${SELECTED_SECTIONS[@]}" && filtered+=("$section")
  done
  SELECTED_SECTIONS=("${filtered[@]}")
}

load_machine_profile() {
  local config="$HOME/.config/dotfiles/machine.conf" key value
  [[ -f "$config" ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      profile)
        [[ "$value" =~ ^[a-z0-9_-]+$ ]] || {
          printf 'Invalid profile in %s\n' "$config" >&2
          return 1
        }
        select_profile "$value"
        return 0
        ;;
    esac
  done <"$config"
  return 1
}

resolve_selection() {
  if [[ -z "$SELECTION_MODE" ]]; then
    if [[ ${#WITH_SECTIONS[@]} -gt 0 ]]; then
      select_profile base
    elif [[ ${#WITHOUT_SECTIONS[@]} -gt 0 ]]; then
      select_profile full
    elif load_machine_profile; then
      :
    elif [[ "$MENU_REQUESTED" == true || ("$AUTO_APPROVE" == false && (-t 0 || (-t 1 && -r /dev/tty))) ]]; then
      show_menu
    else
      select_profile full
    fi
  fi
  apply_selection_modifiers
  resolve_profile_dependencies
  [[ ${#SELECTED_SECTIONS[@]} -gt 0 ]] || {
    printf 'No install sections selected\n' >&2
    exit 2
  }
}

print_options() {
  local profile
  printf 'Profiles:\n'
  for profile in minimal base developer agent cloud full; do
    printf '  %-10s %s\n' "$profile" "$(profile_sections "$profile")"
  done
  printf 'All sections: %s\n' "$(join_by_comma "${SECTION_ORDER[@]}")"
}

print_plan() {
  printf 'mode=%s\n' "$SELECTION_MODE"
  printf 'profile=%s\n' "${PROFILE_NAME:-custom}"
  printf 'sections=%s\n' "$(join_by_comma "${SELECTED_SECTIONS[@]}")"
  printf 'apply_scripts=false\n'
  printf 'orchestrator=explicit\n'
  printf 'conflict_policy=%s\n' "$DOTFILES_CONFLICT_POLICY"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ -n "${2:-}" ]] || {
        printf '%s\n' '--profile requires a name' >&2
        exit 2
      }
      select_profile "$2"
      AUTO_APPROVE=true
      shift 2
      ;;
    --profile=*)
      select_profile "${1#--profile=}"
      AUTO_APPROVE=true
      shift
      ;;
    --full)
      select_profile full
      AUTO_APPROVE=true
      shift
      ;;
    --base-only)
      select_profile base
      AUTO_APPROVE=true
      shift
      ;;
    --with)
      [[ -n "${2:-}" ]] || {
        printf '%s\n' '--with requires sections' >&2
        exit 2
      }
      parse_csv_sections "$2" WITH_SECTIONS
      AUTO_APPROVE=true
      shift 2
      ;;
    --with=*)
      parse_csv_sections "${1#--with=}" WITH_SECTIONS
      AUTO_APPROVE=true
      shift
      ;;
    --sections)
      [[ -n "${2:-}" ]] || {
        printf '%s\n' '--sections requires sections' >&2
        exit 2
      }
      SELECTED_SECTIONS=()
      parse_csv_sections "$2" SELECTED_SECTIONS
      PROFILE_NAME=custom
      SELECTION_MODE=custom
      AUTO_APPROVE=true
      shift 2
      ;;
    --sections=*)
      SELECTED_SECTIONS=()
      parse_csv_sections "${1#--sections=}" SELECTED_SECTIONS
      PROFILE_NAME=custom
      SELECTION_MODE=custom
      AUTO_APPROVE=true
      shift
      ;;
    --without)
      [[ -n "${2:-}" ]] || {
        printf '%s\n' '--without requires sections' >&2
        exit 2
      }
      parse_csv_sections "$2" WITHOUT_SECTIONS
      AUTO_APPROVE=true
      shift 2
      ;;
    --without=*)
      parse_csv_sections "${1#--without=}" WITHOUT_SECTIONS
      AUTO_APPROVE=true
      shift
      ;;
    --menu)
      MENU_REQUESTED=true
      shift
      ;;
    -y | --yes)
      AUTO_APPROVE=true
      shift
      ;;
    --resume)
      RESUME_REQUEST=latest
      AUTO_APPROVE=true
      shift
      ;;
    --resume=*)
      RESUME_REQUEST="${1#--resume=}"
      AUTO_APPROVE=true
      shift
      ;;
    --conflict-policy)
      [[ -n "${2:-}" ]] || {
        printf '%s\n' '--conflict-policy requires a value' >&2
        exit 2
      }
      DOTFILES_CONFLICT_POLICY="$2"
      shift 2
      ;;
    --conflict-policy=*)
      DOTFILES_CONFLICT_POLICY="${1#--conflict-policy=}"
      shift
      ;;
    --source)
      [[ -n "${2:-}" ]] || {
        printf '%s\n' '--source requires a path' >&2
        exit 2
      }
      SOURCE_OVERRIDE="$2"
      LOCAL_SOURCE="$2"
      shift 2
      ;;
    --source=*)
      SOURCE_OVERRIDE="${1#--source=}"
      LOCAL_SOURCE="$SOURCE_OVERRIDE"
      shift
      ;;
    --only)
      [[ -n "${2:-}" ]] || {
        printf '%s\n' '--only requires a section' >&2
        exit 2
      }
      ONLY_SECTION="$2"
      shift 2
      ;;
    --no-doctor)
      RUN_DOCTOR=false
      shift
      ;;
    --print-plan)
      PRINT_PLAN=true
      AUTO_APPROVE=true
      shift
      ;;
    --list-options)
      LIST_OPTIONS=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$DOTFILES_CONFLICT_POLICY" in
  backup | skip | abort) ;;
  *)
    printf 'Invalid conflict policy: %s\n' "$DOTFILES_CONFLICT_POLICY" >&2
    exit 2
    ;;
esac

if [[ -n "$ONLY_SECTION" ]]; then
  contains_section "$ONLY_SECTION" || {
    printf 'Unknown section: %s\n' "$ONLY_SECTION" >&2
    exit 2
  }
  [[ -n "$LOCAL_SOURCE" ]] || {
    printf '%s\n' '--only requires a local checkout' >&2
    exit 2
  }
  exec "$LOCAL_SOURCE/scripts/run-section.sh" "$ONLY_SECTION"
fi

STATE_ROOT="${DOTFILES_STATE_DIR:-$HOME/.local/state/dotfiles}"
if [[ -n "$RESUME_REQUEST" ]]; then
  if [[ "$RESUME_REQUEST" == latest ]]; then
    [[ -f "$STATE_ROOT/runs/latest" ]] || {
      printf '%s\n' 'No interrupted run is available' >&2
      exit 2
    }
    RESOLVED_RESUME_ID="$(<"$STATE_ROOT/runs/latest")"
  else
    RESOLVED_RESUME_ID="$RESUME_REQUEST"
  fi
  [[ -d "$STATE_ROOT/runs/$RESOLVED_RESUME_ID" ]] || {
    printf 'Unknown run id: %s\n' "$RESOLVED_RESUME_ID" >&2
    exit 2
  }
  if [[ -f "$STATE_ROOT/runs/$RESOLVED_RESUME_ID/sections" ]]; then
    SELECTED_SECTIONS=()
    parse_csv_sections "$(<"$STATE_ROOT/runs/$RESOLVED_RESUME_ID/sections")" SELECTED_SECTIONS
    PROFILE_NAME="$(<"$STATE_ROOT/runs/$RESOLVED_RESUME_ID/profile")"
    SELECTION_MODE=resume
  fi
fi

resolve_selection
if [[ "$LIST_OPTIONS" == true ]]; then
  print_options
  exit 0
fi
if [[ "$PRINT_PLAN" == true ]]; then
  print_plan
  exit 0
fi

if [[ -n "$RESUME_REQUEST" ]]; then
  DOTFILES_RUN_ID="$RESOLVED_RESUME_ID"
else
  DOTFILES_RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
fi
export DOTFILES_RUN_ID
RUN_DIR="$STATE_ROOT/runs/$DOTFILES_RUN_ID"
CHECKPOINT_DIR="$RUN_DIR/checkpoints"
LOG_DIR="$STATE_ROOT/logs"
LOG_FILE="${DOTFILES_LOG_FILE:-$LOG_DIR/bootstrap-$DOTFILES_RUN_ID.log}"
EVENT_LOG="$LOG_DIR/bootstrap-$DOTFILES_RUN_ID.jsonl"
export DOTFILES_EVENT_LOG="$EVENT_LOG"

setup_run_state() {
  umask 077
  mkdir -p "$CHECKPOINT_DIR" "$LOG_DIR"
  printf '%s\n' "$DOTFILES_RUN_ID" >"$STATE_ROOT/runs/latest"
  printf '%s\n' "${PROFILE_NAME:-custom}" >"$RUN_DIR/profile"
  printf '%s\n' "$(join_by_comma "${SELECTED_SECTIONS[@]}")" >"$RUN_DIR/sections"
  chmod 600 "$STATE_ROOT/runs/latest" "$RUN_DIR/profile" "$RUN_DIR/sections"

  if [[ "$DOTFILES_LOG" != 0 ]]; then
    touch "$LOG_FILE" "$EVENT_LOG"
    chmod 600 "$LOG_FILE" "$EVENT_LOG"
    exec > >(
      tee >(
        sed -u -E \
          -e $'s/\033\\[[0-9;]*[[:alpha:]]//g' \
          -e 's/((token|password|secret|api[_-]?key)[=:][[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
          >>"$LOG_FILE"
      )
    ) 2>&1
  fi

  find "$LOG_DIR" -maxdepth 1 -type f -name 'bootstrap-*' -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    awk -v keep="$DOTFILES_LOG_RETENTION" 'NR > keep {sub(/^[^ ]+ /, ""); print}' |
    xargs -r rm -f
}

write_event() {
  local level="$1"
  shift
  local message="${*//\\/\\\\}"
  message="${message//\"/\\\"}"
  printf '{"time":"%s","run_id":"%s","stage":"%s","level":"%s","message":"%s"}\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$DOTFILES_RUN_ID" "$CURRENT_STAGE" "$level" "$message" >>"$EVENT_LOG"
}

on_error() {
  local status="$1" line="$2"
  [[ "$_HANDLING_ERROR" == false ]] || exit "$status"
  _HANDLING_ERROR=true
  log_error "Stage '$CURRENT_STAGE' failed at installer line $line (exit $status)"
  log_info "Resume after fixing the cause: $0 --resume=$DOTFILES_RUN_ID"
  log_info "Text log: $LOG_FILE"
  log_info "Event log: $EVENT_LOG"
  write_event error "failed line=$line exit=$status"
  if [[ -n "${CHEZMOI_SOURCE:-}" ]]; then
    write_run_summary failure 2>/dev/null || true
  fi
  exit "$status"
}

setup_run_state
trap 'on_error $? $LINENO' ERR

if [[ -n "$RESUME_REQUEST" && -f "$RUN_DIR/source" ]]; then
  CHEZMOI_SOURCE="$(<"$RUN_DIR/source")"
  export DOTFILES_SOURCE_DIR="$CHEZMOI_SOURCE"
fi

stage_injection_matches() {
  local point="$1" requested="${DOTFILES_FAIL_AT:-}"
  [[ "$requested" == "$CURRENT_STAGE:$point" || "$requested" == "$point:$CURRENT_STAGE" ]]
}

run_stage() {
  local stage="$1"
  shift
  local checkpoint="$CHECKPOINT_DIR/$stage.done" started elapsed
  CURRENT_STAGE="$stage"
  if [[ -n "$RESUME_REQUEST" && -f "$checkpoint" ]]; then
    log_skip "Resuming: $stage already completed"
    write_event skip "checkpoint hit"
    return 0
  fi

  log_step "$stage"
  write_event start "stage started"
  if stage_injection_matches before; then
    log_error "Injected failure before $stage"
    return 97
  fi
  started="$(date +%s)"
  "$@"
  elapsed=$(($(date +%s) - started))
  printf '%s\n' "$elapsed" >"$checkpoint"
  chmod 600 "$checkpoint"
  log_success "$stage completed in ${elapsed}s"
  write_event success "duration_seconds=$elapsed"
  if stage_injection_matches after; then
    log_error "Injected failure after $stage"
    return 98
  fi
  return 0
}

bootstrap_download() {
  local url="$1" dest="$2"
  curl --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors -fsSLo "$dest" "$url"
}

install_chezmoi_fallback() {
  local version="${DOTFILES_CHEZMOI_VERSION:-2.71.0}" arch asset base tmp expected
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
  esac
  asset="chezmoi_${version}_linux_${arch}.tar.gz"
  base="https://github.com/twpayne/chezmoi/releases/download/v${version}"
  tmp="$(mktemp -d)"
  bootstrap_download "$base/$asset" "$tmp/$asset"
  bootstrap_download "$base/chezmoi_${version}_checksums.txt" "$tmp/checksums.txt"
  expected="$(awk -v asset="$asset" '$2 == asset {print $1}' "$tmp/checksums.txt")"
  [[ -n "$expected" ]] || {
    rm -rf "$tmp"
    return 1
  }
  printf '%s  %s\n' "$expected" "$tmp/$asset" | sha256sum -c -
  tar -xzf "$tmp/$asset" -C "$tmp" chezmoi
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$tmp/chezmoi" "$HOME/.local/bin/chezmoi"
  rm -rf "$tmp"
  export PATH="$HOME/.local/bin:$PATH"
}

stage_prerequisites() {
  if [[ "$(id -u)" -ne 0 ]]; then
    sudo -v
    SUDO=(sudo)
  else
    SUDO=()
  fi
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o Acquire::Retries=3 -qq update
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o Acquire::Retries=3 -o Dpkg::Options::=--force-confold \
    -y --no-install-recommends install git curl ca-certificates

  if ! command -v chezmoi >/dev/null 2>&1; then
    if "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
      apt-get -y --no-install-recommends install chezmoi; then
      log_success "chezmoi installed from Ubuntu's signed repository"
    else
      log_warn "Ubuntu did not provide chezmoi; using verified upstream release"
      install_chezmoi_fallback
      log_success "chezmoi installed from verified upstream release"
    fi
  else
    log_skip "chezmoi already installed"
  fi
}

stage_source() {
  local name email sessionizer source_path
  name="${DOTFILES_GIT_NAME:-$(git config --global user.name 2>/dev/null || printf 'Idan Botbol')}"
  email="${DOTFILES_GIT_EMAIL:-$(git config --global user.email 2>/dev/null || printf 'botbolidan@gmail.com')}"
  sessionizer="${DOTFILES_SESSIONIZER_DIRS:-~/Code ~/Scripts ~/Education}"
  CHEZMOI_INIT_ARGS=(
    "--promptString=Full name=$name"
    "--promptString=Git email=$email"
    "--promptString=tmux-sessionizer search dirs (space-separated)=$sessionizer"
  )

  if [[ -n "$LOCAL_SOURCE" ]]; then
    [[ -f "$LOCAL_SOURCE/.chezmoi.yaml.tmpl" ]] || {
      log_error "Invalid local source: $LOCAL_SOURCE"
      return 1
    }
    log_info "Using local source: $LOCAL_SOURCE"
    chezmoi init --source="$LOCAL_SOURCE" "${CHEZMOI_INIT_ARGS[@]}"
    CHEZMOI_SOURCE="$LOCAL_SOURCE"
  else
    source_path="$(chezmoi source-path 2>/dev/null || true)"
    if [[ -n "$source_path" && -d "$source_path/.git" ]]; then
      log_info "Updating existing source: $source_path"
      git -C "$source_path" pull --ff-only
      chezmoi init --source="$source_path" "${CHEZMOI_INIT_ARGS[@]}"
      CHEZMOI_SOURCE="$source_path"
    else
      log_info "Cloning source over HTTPS: $DOTFILES_REPO_URL"
      chezmoi init "$DOTFILES_REPO_URL" "${CHEZMOI_INIT_ARGS[@]}"
      CHEZMOI_SOURCE="$(chezmoi source-path)"
    fi
  fi

  export DOTFILES_SOURCE_DIR="$CHEZMOI_SOURCE"
  printf '%s\n' "$CHEZMOI_SOURCE" >"$RUN_DIR/source"
  chmod 600 "$RUN_DIR/source"
  local declared builtin
  declared="$(profile_sections "${PROFILE_NAME:-full}" "$CHEZMOI_SOURCE" 2>/dev/null || true)"
  builtin="${BUILTIN_PROFILES[${PROFILE_NAME:-full}]:-}"
  if [[ "$PROFILE_NAME" != custom && -n "$declared" && -n "$builtin" && "$declared" != "$builtin" ]]; then
    log_error "Embedded profile '$PROFILE_NAME' drifted from profiles/$PROFILE_NAME.conf"
    return 1
  fi
}

collect_chezmoi_status() {
  local status
  if ! status="$(chezmoi status --source="$CHEZMOI_SOURCE" --exclude=scripts)"; then
    log_error "Unable to calculate chezmoi status from $CHEZMOI_SOURCE"
    return 1
  fi
  CHEZMOI_STATUS_OUTPUT="$status"
}

print_dry_run_summary() {
  local total
  collect_chezmoi_status
  if [[ -z "$CHEZMOI_STATUS_OUTPUT" ]]; then
    log_info "Chezmoi dry run: no config changes pending"
    return 0
  fi
  total="$(wc -l <<<"$CHEZMOI_STATUS_OUTPUT" | tr -d ' ')"
  log_info "Chezmoi dry run: $total path(s) pending"
  sed -n '1,12p' <<<"$CHEZMOI_STATUS_OUTPUT" | while IFS= read -r line; do
    log_info "  $line"
  done
  [[ "$total" -le 12 ]] || log_info "  ... $((total - 12)) more; run 'chezmoi diff' for the full diff"
}

stage_apply() {
  local status_file backup_output
  print_dry_run_summary
  if [[ -n "$CHEZMOI_STATUS_OUTPUT" ]]; then
    case "$DOTFILES_CONFLICT_POLICY" in
      skip)
        log_warn "Conflict policy is skip; preserving current destination files"
        log_info "Applying verified externals without overwriting managed config"
        chezmoi apply --source="$CHEZMOI_SOURCE" --include=dirs,externals --force
        return 0
        ;;
      abort)
        log_error "Pending chezmoi changes found and conflict policy is abort"
        return 1
        ;;
      backup) ;;
    esac

    status_file="$RUN_DIR/chezmoi-status.txt"
    printf '%s\n' "$CHEZMOI_STATUS_OUTPUT" >"$status_file"
    chmod 600 "$status_file"
    backup_output="$($CHEZMOI_SOURCE/scripts/backup.sh create --status-file "$status_file" --run-id "$DOTFILES_RUN_ID")"
    BACKUP_ID="$(sed -n 's/^backup_id=//p' <<<"$backup_output" | tail -1)"
    [[ -n "$BACKUP_ID" ]] || {
      log_error "Backup did not return an identifier"
      return 1
    }
    log_success "Backed up pending destinations as $BACKUP_ID"
  else
    log_info "Applying managed config and verified externals to confirm convergence"
  fi

  log_info "Applying dotfiles with scripts delegated to the observable orchestrator"
  if ! chezmoi apply --source="$CHEZMOI_SOURCE" --exclude=scripts --force; then
    if [[ "$DOTFILES_ROLLBACK_ON_ERROR" == 1 && -n "$BACKUP_ID" ]]; then
      log_warn "Chezmoi apply failed; restoring backup $BACKUP_ID"
      "$CHEZMOI_SOURCE/scripts/backup.sh" restore "$BACKUP_ID" --force
    fi
    return 1
  fi
}

declare -A SECTION_SCRIPTS=(
  [detect]=".chezmoiscripts/run_once_before_00-detect-environment.sh.tmpl"
  [core]=".chezmoiscripts/run_once_before_01-install-core-packages.sh.tmpl"
  [zsh]=".chezmoiscripts/run_once_before_02-install-zsh-ecosystem.sh.tmpl"
  [terminal]=".chezmoiscripts/run_once_before_03-install-terminal-tools.sh.tmpl"
  [languages]=".chezmoiscripts/run_once_04-install-languages.sh.tmpl"
  [history]=".chezmoiscripts/run_once_04b-install-history.sh.tmpl"
  [cloud]=".chezmoiscripts/run_once_05-install-containers-cloud.sh.tmpl"
  [tmux]=".chezmoiscripts/run_once_06-install-tmux-ecosystem.sh.tmpl"
  [neovim]=".chezmoiscripts/run_once_07-install-neovim.sh.tmpl"
  [ai]=".chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl"
  [media]=".chezmoiscripts/run_once_09-install-media-tools.sh.tmpl"
  [fonts]=".chezmoiscripts/run_once_10-install-fonts.sh.tmpl"
  [desktop]=".chezmoiscripts/run_once_11-install-desktop.sh.tmpl"
  [system]=".chezmoiscripts/run_once_12-configure-system.sh.tmpl"
  [theme]=".chezmoiscripts/run_once_13-apply-catppuccin-theme.sh.tmpl"
  [vscode]=".chezmoiscripts/run_once_14-install-vscode-extensions.sh.tmpl"
  [services]=".chezmoiscripts/run_once_after_enable-services.sh.tmpl"
)

declare -A SECTION_MANIFESTS=(
  [terminal]=core
  [languages]=languages
  [history]=history
  [cloud]=cloud
  [tmux]=terminal
  [neovim]=editor
  [ai]=ai_tools
  [media]=media
  [fonts]=fonts
  [desktop]=terminal
  [system]=system
)

run_install_section() {
  local section="$1" script_path hash_dir manifest_section
  script_path="${SECTION_SCRIPTS[$section]:-}"
  [[ -n "$script_path" && -f "$CHEZMOI_SOURCE/$script_path" ]] || {
    log_error "Missing section implementation for $section"
    return 1
  }
  export DOTFILES_SECTION="$section"
  DOTFILES_SOURCE_DIR="$CHEZMOI_SOURCE" chezmoi execute-template --source="$CHEZMOI_SOURCE" \
    <"$CHEZMOI_SOURCE/$script_path" |
    DOTFILES_SOURCE_DIR="$CHEZMOI_SOURCE" \
      DOTFILES_SECTION="$section" \
      DOTFILES_RUN_ID="$DOTFILES_RUN_ID" \
      DOTFILES_EVENT_LOG="$EVENT_LOG" \
      DOTFILES_COLOR_ACTIVE="$DOTFILES_COLOR_ACTIVE" \
      bash

  manifest_section="${SECTION_MANIFESTS[$section]:-}"
  [[ -n "$manifest_section" ]] || return 0
  hash_dir="$STATE_ROOT/package-sections"
  mkdir -p "$hash_dir"
  awk -v section="$manifest_section" '
    $0 ~ "^" section ":[[:space:]]*$" { inside = 1 }
    inside && $0 ~ "^[^[:space:]#].*:[[:space:]]*$" && $0 !~ "^" section ":" { exit }
    inside { print }
  ' "$CHEZMOI_SOURCE/packages.yaml" | sha256sum | awk '{print $1}' >"$hash_dir/$manifest_section.sha256"
  chmod 600 "$hash_dir/$manifest_section.sha256"
}

stage_doctor() {
  "$CHEZMOI_SOURCE/scripts/doctor.sh" \
    --acceptance \
    --sections "$(join_by_comma "${SELECTED_SECTIONS[@]}")"
}

write_run_summary() {
  local status="$1" ended duration summary
  ended="$(date +%s)"
  duration=$((ended - RUN_STARTED_EPOCH))
  summary="$RUN_DIR/summary.json"
  printf '{\n  "run_id": "%s",\n  "status": "%s",\n  "profile": "%s",\n  "platform": "%s",\n  "sections": "%s",\n  "duration_seconds": %s,\n  "backup_id": "%s",\n  "log": "%s"\n}\n' \
    "$DOTFILES_RUN_ID" "$status" "${PROFILE_NAME:-custom}" \
    "$(
      source "$CHEZMOI_SOURCE/scripts/environment.sh"
      get_platform
    )" \
    "$(join_by_comma "${SELECTED_SECTIONS[@]}")" "$duration" "$BACKUP_ID" "$LOG_FILE" >"$summary"
  chmod 600 "$summary"
}

log_banner "Dotfiles Bootstrap - Idan Botbol"
log_info "Run ID: $DOTFILES_RUN_ID"
log_info "Profile: ${PROFILE_NAME:-custom}"
log_info "Sections: $(join_by_comma "${SELECTED_SECTIONS[@]}")"
log_info "Conflict policy: $DOTFILES_CONFLICT_POLICY"
log_info "Log: $LOG_FILE"

run_stage prerequisites stage_prerequisites
run_stage source stage_source

# From this point all platform behavior comes from one shared implementation.
# shellcheck source=scripts/environment.sh
source "$CHEZMOI_SOURCE/scripts/environment.sh"
if ! assert_supported_platform; then
  log_error "Unsupported platform $(get_platform); this repository supports Ubuntu 24.04 native and WSL"
  exit 1
fi
log_info "Platform: $(get_platform) ($(get_arch))"

run_stage apply stage_apply
for section in "${SELECTED_SECTIONS[@]}"; do
  run_stage "section-$section" run_install_section "$section"
done
if [[ "$RUN_DOCTOR" == true ]]; then
  run_stage doctor stage_doctor
fi

write_run_summary success
rm -f "$STATE_ROOT/runs/latest"

printf '\n'
log_banner "Bootstrap Complete"
log_success "Completed in $(($(date +%s) - RUN_STARTED_EPOCH))s"
log_info "Run summary: $RUN_DIR/summary.json"
log_info "Restore configs: $CHEZMOI_SOURCE/scripts/backup.sh restore ${BACKUP_ID:-<backup-id>}"
log_info "Authentication remains manual; run 'dot doctor' after signing in to selected tools"
printf '\nNext steps:\n'
printf '  1. Restart the shell: exec zsh\n'
printf '  2. Start an agent workspace: dot workspace\n'
printf '  3. Review health: dot doctor\n'
