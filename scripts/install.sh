#!/usr/bin/env bash
# install.sh - Bootstrap for Ubuntu 24.04 (native or WSL)
# Usage: curl -fsSL https://raw.githubusercontent.com/Idanbot/.dotfiles/main/scripts/install.sh | bash
# Or:    git clone https://github.com/Idanbot/.dotfiles.git ~/.dotfiles && ~/.dotfiles/scripts/install.sh

set -euo pipefail

DOTFILES_REPO_URL="${DOTFILES_REPO_URL:-https://github.com/Idanbot/.dotfiles.git}"
SCRIPT_DIR=""
LOCAL_SOURCE=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/../.chezmoi.yaml.tmpl" ]]; then
    LOCAL_SOURCE="$(cd "$SCRIPT_DIR/.." && pwd)"
  fi
fi

SECTION_ORDER=(
  detect
  core
  zsh
  terminal
  languages
  cloud
  tmux
  neovim
  ai
  media
  fonts
  desktop
  system
  theme
  vscode
  services
)

BASE_SECTIONS=(detect core zsh terminal)
OPTIONAL_SECTIONS=(languages cloud tmux neovim ai media fonts desktop system theme vscode services)
SELECTED_SECTIONS=()
WITH_SECTIONS=()
WITHOUT_SECTIONS=()
SELECTION_MODE=""
AUTO_APPROVE=false
PRINT_PLAN=false
LIST_OPTIONS=false
MENU_REQUESTED=false

usage() {
  cat <<'USAGE'
Usage: scripts/install.sh [options]

Install profiles:
  --full                    Install all sections (default for noninteractive use)
  --base-only               Install base sections only: detect, core, zsh, terminal
  --with <a,b>              Install base plus optional sections
  --sections <a,b>          Install exactly these sections
  --without <a,b>           Remove sections from the selected profile
  --menu                    Show the interactive selector even if flags are absent
  -y, --yes                 Do not prompt; accept the selected/default profile
  --only <section>          Run one section from an existing local checkout

Utility:
  --list-options            Print available sections and exit
  --print-plan              Print the resolved plan and exit without installing
  -h, --help                Show this help

Optional sections:
  languages, cloud, tmux, neovim, ai, media, fonts, desktop, system, theme, vscode, services

Examples:
  scripts/install.sh --base-only -y
  scripts/install.sh --with languages,tmux,neovim -y
  scripts/install.sh --sections core,languages -y
  curl -fsSL https://raw.githubusercontent.com/Idanbot/.dotfiles/main/scripts/install.sh | bash -s -- --base-only -y
USAGE
}

join_by_comma() {
  local IFS=,
  echo "$*"
}

contains_section() {
  local needle="$1"
  local section
  for section in "${SECTION_ORDER[@]}"; do
    if [[ "$section" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

array_has() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

add_section_once() {
  local section="$1"
  if ! array_has "$section" "${SELECTED_SECTIONS[@]}"; then
    SELECTED_SECTIONS+=("$section")
  fi
}

parse_csv_sections() {
  local value="$1"
  local -n out_ref="$2"
  local raw section
  IFS=',' read -ra raw <<<"$value"
  for section in "${raw[@]}"; do
    section="${section//[[:space:]]/}"
    [[ -z "$section" ]] && continue
    if ! contains_section "$section"; then
      echo "Unknown section: $section" >&2
      echo "Run scripts/install.sh --list-options for valid sections." >&2
      exit 2
    fi
    out_ref+=("$section")
  done
}

print_options() {
  echo "Profiles: full, base-only, custom"
  echo "Base sections: $(join_by_comma "${BASE_SECTIONS[@]}")"
  echo "Optional sections: $(join_by_comma "${OPTIONAL_SECTIONS[@]}")"
  echo "All sections: $(join_by_comma "${SECTION_ORDER[@]}")"
}

select_base() {
  SELECTION_MODE="base"
  SELECTED_SECTIONS=("${BASE_SECTIONS[@]}")
}

select_full() {
  SELECTION_MODE="full"
  SELECTED_SECTIONS=("${SECTION_ORDER[@]}")
}

select_exact() {
  SELECTION_MODE="custom"
  SELECTED_SECTIONS=("$@")
}

apply_with_sections() {
  local section
  for section in "${WITH_SECTIONS[@]}"; do
    add_section_once "$section"
  done
}

apply_without_sections() {
  local filtered=()
  local section skip
  for section in "${SELECTED_SECTIONS[@]}"; do
    skip=false
    if array_has "$section" "${WITHOUT_SECTIONS[@]}"; then
      skip=true
    fi
    if [[ "$skip" == "false" ]]; then
      filtered+=("$section")
    fi
  done
  SELECTED_SECTIONS=("${filtered[@]}")
}

sort_selected_sections() {
  local sorted=()
  local section
  for section in "${SECTION_ORDER[@]}"; do
    if array_has "$section" "${SELECTED_SECTIONS[@]}"; then
      sorted+=("$section")
    fi
  done
  SELECTED_SECTIONS=("${sorted[@]}")
}

show_menu() {
  local choice extras
  echo
  echo "══════════════════════════════════════════════"
  echo "  Install Profile"
  echo "══════════════════════════════════════════════"
  echo "  1. Full install"
  echo "  2. Base only (${BASE_SECTIONS[*]})"
  echo "  3. Base + selected optional sections"
  echo "  4. Exact section list"
  echo
  read -rp "Choose install profile [1]: " choice
  case "${choice:-1}" in
    1)
      select_full
      ;;
    2)
      select_base
      ;;
    3)
      select_base
      echo "Optional sections: $(join_by_comma "${OPTIONAL_SECTIONS[@]}")"
      read -rp "Add sections (comma-separated): " extras
      parse_csv_sections "$extras" WITH_SECTIONS
      apply_with_sections
      SELECTION_MODE="custom"
      ;;
    4)
      echo "All sections: $(join_by_comma "${SECTION_ORDER[@]}")"
      read -rp "Sections (comma-separated): " extras
      SELECTED_SECTIONS=()
      parse_csv_sections "$extras" SELECTED_SECTIONS
      SELECTION_MODE="custom"
      ;;
    *)
      echo "Unknown menu choice: $choice" >&2
      exit 2
      ;;
  esac
}

resolve_selection() {
  if [[ -z "$SELECTION_MODE" ]]; then
    if [[ ${#WITH_SECTIONS[@]} -gt 0 ]]; then
      select_base
    elif [[ ${#WITHOUT_SECTIONS[@]} -gt 0 ]]; then
      select_full
    elif [[ "$MENU_REQUESTED" == "true" || ("$AUTO_APPROVE" == "false" && -t 0) ]]; then
      show_menu
    else
      select_full
    fi
  fi

  apply_with_sections
  apply_without_sections
  sort_selected_sections

  if [[ ${#SELECTED_SECTIONS[@]} -eq 0 ]]; then
    echo "No install sections selected." >&2
    exit 2
  fi
}

print_plan() {
  echo "mode=$SELECTION_MODE"
  echo "sections=$(join_by_comma "${SELECTED_SECTIONS[@]}")"
  if [[ "$SELECTION_MODE" == "full" && ${#WITHOUT_SECTIONS[@]} -eq 0 ]]; then
    echo "apply_scripts=true"
  else
    echo "apply_scripts=false"
  fi
}

CHEZMOI_STATUS_OUTPUT=""
SKIP_CHEZMOI_APPLY=false

chezmoi_exclude_args() {
  if [[ ${#APPLY_EXCLUDES[@]} -gt 0 ]]; then
    echo "--exclude=$(join_by_comma "${APPLY_EXCLUDES[@]}")"
  fi
}

collect_chezmoi_status() {
  local exclude_arg
  exclude_arg="$(chezmoi_exclude_args)"
  if [[ -n "$exclude_arg" ]]; then
    CHEZMOI_STATUS_OUTPUT="$(chezmoi status "$exclude_arg" 2>/dev/null || true)"
  else
    CHEZMOI_STATUS_OUTPUT="$(chezmoi status 2>/dev/null || true)"
  fi
}

print_chezmoi_dry_run_summary() {
  local total added modified deleted other exclude_arg diff_preview

  echo "[INFO] Chezmoi dry-run summary:"
  if [[ ${#APPLY_EXCLUDES[@]} -gt 0 ]]; then
    echo "[INFO]   Excluding: $(join_by_comma "${APPLY_EXCLUDES[@]}")"
  fi
  if [[ -z "$CHEZMOI_STATUS_OUTPUT" ]]; then
    echo "[INFO]   No dotfile changes pending"
    return 0
  fi

  total=$(wc -l <<<"$CHEZMOI_STATUS_OUTPUT" | tr -d ' ')
  added=$(grep -cE '(^| )[A][A-Z? ]*[[:space:]]' <<<"$CHEZMOI_STATUS_OUTPUT" || true)
  modified=$(grep -cE '(^| )[M][A-Z? ]*[[:space:]]' <<<"$CHEZMOI_STATUS_OUTPUT" || true)
  deleted=$(grep -cE '(^| )[D][A-Z? ]*[[:space:]]' <<<"$CHEZMOI_STATUS_OUTPUT" || true)
  other=$((total - added - modified - deleted))

  echo "[INFO]   Pending: $total total, $added create, $modified modify, $deleted delete, $other other"
  echo "[INFO]   First pending paths:"
  sed -n '1,25p' <<<"$CHEZMOI_STATUS_OUTPUT" | sed 's/^/[INFO]     /'
  if [[ $total -gt 25 ]]; then
    echo "[INFO]     ... $((total - 25)) more"
  fi

  exclude_arg="$(chezmoi_exclude_args)"
  echo "[INFO]   Full dry-run diff command: chezmoi diff ${exclude_arg}"
  if [[ -n "$exclude_arg" ]]; then
    diff_preview="$(chezmoi diff "$exclude_arg" 2>/dev/null | sed -n '1,80p' || true)"
  else
    diff_preview="$(chezmoi diff 2>/dev/null | sed -n '1,80p' || true)"
  fi
  if [[ -n "$diff_preview" ]]; then
    echo "[INFO]   Diff preview (first 80 lines):"
    sed 's/^/[INFO]     /' <<<"$diff_preview"
  fi
}

find_chezmoi_conflicts() {
  local line trimmed state rel target
  [[ -n "$CHEZMOI_STATUS_OUTPUT" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    trimmed="${line#"${line%%[![:space:]]*}"}"
    state="${trimmed%%[[:space:]]*}"
    rel="${trimmed#"$state"}"
    rel="${rel#"${rel%%[![:space:]]*}"}"
    [[ -n "$state" && -n "$rel" ]] || continue
    target="$HOME/$rel"
    if [[ "$state" == *A* && -e "$target" ]]; then
      printf '%s\n' "$rel"
    fi
  done <<<"$CHEZMOI_STATUS_OUTPUT"
}

backup_chezmoi_conflicts() {
  local backup_dir rel target dest
  backup_dir="$HOME/.local/state/dotfiles/backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    target="$HOME/$rel"
    dest="$backup_dir/$rel"
    mkdir -p "$(dirname "$dest")"
    mv "$target" "$dest"
    echo "[INFO]   Backed up ~/$rel -> ${dest/#$HOME/~}"
  done
  echo "[INFO] Conflict backup directory: ${backup_dir/#$HOME/~}"
}

handle_chezmoi_conflicts() {
  local conflicts count action
  conflicts="$(find_chezmoi_conflicts)"
  [[ -n "$conflicts" ]] || return 0
  count=$(wc -l <<<"$conflicts" | tr -d ' ')

  echo "[WARN] Chezmoi would create $count path(s) that already exist locally:"
  sed -n '1,25p' <<<"$conflicts" | sed 's/^/[WARN]   ~\//'
  if [[ $count -gt 25 ]]; then
    echo "[WARN]   ... $((count - 25)) more"
  fi

  if [[ "$AUTO_APPROVE" == "true" || ! -t 0 ]]; then
    action=backup
    echo "[INFO] Noninteractive run: backing up conflicts before apply"
  else
    echo "Options: [B]ack up and continue, [s]kip dotfile apply, [a]bort"
    read -rp "Choose conflict action [B]: " action
    case "${action:-b}" in
      [Bb]*) action=backup ;;
      [Ss]*) action=skip ;;
      [Aa]*) action=abort ;;
      *)
        echo "Unknown action: $action" >&2
        exit 2
        ;;
    esac
  fi

  case "$action" in
    backup)
      backup_chezmoi_conflicts <<<"$conflicts"
      collect_chezmoi_status
      ;;
    skip)
      SKIP_CHEZMOI_APPLY=true
      echo "[WARN] Skipping chezmoi apply because local conflicts were preserved"
      ;;
    abort)
      echo "[ERROR] Aborting before apply; no conflicting files were changed" >&2
      exit 1
      ;;
  esac
}

run_chezmoi_apply() {
  local exclude_arg
  exclude_arg="$(chezmoi_exclude_args)"
  if [[ -n "$exclude_arg" ]]; then
    chezmoi apply "$exclude_arg"
  else
    chezmoi apply
  fi
}

if [[ "${1:-}" == "--only" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "Usage: ./scripts/install.sh --only <section>" >&2
    exit 1
  fi
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-section.sh" "$2"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)
      select_full
      AUTO_APPROVE=true
      shift
      ;;
    --base-only)
      select_base
      AUTO_APPROVE=true
      shift
      ;;
    --with)
      [[ -n "${2:-}" ]] || {
        echo "--with requires a comma-separated section list" >&2
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
        echo "--sections requires a comma-separated section list" >&2
        exit 2
      }
      SELECTED_SECTIONS=()
      parse_csv_sections "$2" SELECTED_SECTIONS
      SELECTION_MODE="custom"
      AUTO_APPROVE=true
      shift 2
      ;;
    --sections=*)
      SELECTED_SECTIONS=()
      parse_csv_sections "${1#--sections=}" SELECTED_SECTIONS
      SELECTION_MODE="custom"
      AUTO_APPROVE=true
      shift
      ;;
    --without)
      [[ -n "${2:-}" ]] || {
        echo "--without requires a comma-separated section list" >&2
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
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$LIST_OPTIONS" == "true" ]]; then
  print_options
  exit 0
fi

resolve_selection

if [[ "$PRINT_PLAN" == "true" ]]; then
  print_plan
  exit 0
fi

declare -A SECTION_SCRIPTS=(
  [detect]=".chezmoiscripts/run_once_before_00-detect-environment.sh.tmpl"
  [core]=".chezmoiscripts/run_once_before_01-install-core-packages.sh.tmpl"
  [zsh]=".chezmoiscripts/run_once_before_02-install-zsh-ecosystem.sh.tmpl"
  [terminal]=".chezmoiscripts/run_once_before_03-install-terminal-tools.sh.tmpl"
  [languages]=".chezmoiscripts/run_once_04-install-languages.sh.tmpl"
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

run_install_section() {
  local source_dir="$1" section="$2"
  local script="${SECTION_SCRIPTS[$section]:-}"
  local script_path
  if [[ -z "$script" ]]; then
    echo "Unknown section: $section" >&2
    return 1
  fi
  script_path="$source_dir/$script"
  if [[ ! -f "$script_path" ]]; then
    echo "Missing section script: $script_path" >&2
    return 1
  fi
  DOTFILES_SOURCE_DIR="$source_dir" chezmoi execute-template <"$script_path" | DOTFILES_SOURCE_DIR="$source_dir" bash
}

echo "══════════════════════════════════════════════"
echo "  Dotfiles Bootstrap — Idan Botbol"
echo "══════════════════════════════════════════════"
echo

# Detect environment
if grep -qi microsoft /proc/version 2>/dev/null; then
  echo "[INFO] WSL environment detected"
else
  echo "[INFO] Native Linux environment detected"
fi

echo "[INFO] Install profile: $SELECTION_MODE"
echo "[INFO] Selected sections: $(join_by_comma "${SELECTED_SECTIONS[@]}")"

# Install prerequisites
echo "[INFO] Installing prerequisites (git, curl)..."
sudo apt-get update -qq
sudo apt-get install -y -qq git curl

CHEZMOI_INIT_ARGS=()
DOTFILES_GIT_NAME="${DOTFILES_GIT_NAME:-$(git config --global user.name 2>/dev/null || true)}"
DOTFILES_GIT_EMAIL="${DOTFILES_GIT_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"
if [[ -n "$DOTFILES_GIT_NAME" ]]; then
  CHEZMOI_INIT_ARGS+=(--promptString="Full name=$DOTFILES_GIT_NAME")
fi
if [[ -n "$DOTFILES_GIT_EMAIL" ]]; then
  CHEZMOI_INIT_ARGS+=(--promptString="Git email=$DOTFILES_GIT_EMAIL")
fi

# Install chezmoi
if ! command -v chezmoi &>/dev/null; then
  echo "[INFO] Installing chezmoi..."
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
  echo "[OK] chezmoi installed"
else
  echo "[SKIP] chezmoi already installed"
fi

# Install age for secret decryption
if ! command -v age &>/dev/null; then
  echo "[INFO] Installing age..."
  sudo apt-get install -y -qq age
  echo "[OK] age installed"
else
  echo "[SKIP] age already installed"
fi

APPLY_EXCLUDES=()

# Check for age identity key
if [[ ! -f "$HOME/.config/chezmoi/key.txt" ]]; then
  echo
  echo "══════════════════════════════════════════════"
  echo "  Age Identity Key Required"
  echo "══════════════════════════════════════════════"
  echo
  echo "No age identity key found at ~/.config/chezmoi/key.txt"
  echo
  echo "Options:"
  echo "  1. Import existing key: Copy your backed-up key.txt to ~/.config/chezmoi/key.txt"
  echo "  2. Generate new key:    age-keygen -o ~/.config/chezmoi/key.txt"
  echo "     (Then update the recipient in .chezmoi.yaml and re-encrypt secrets)"
  echo
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    response=n
  else
    read -rp "Do you have an existing key to import? [y/N] " response
  fi
  if [[ "$response" =~ ^[Yy]$ ]]; then
    echo "Please place your key at ~/.config/chezmoi/key.txt and re-run this script."
    exit 0
  else
    echo "[INFO] Generating new age identity key..."
    mkdir -p "$HOME/.config/chezmoi"
    age-keygen -o "$HOME/.config/chezmoi/key.txt" 2>&1 | tee /dev/stderr
    chmod 600 "$HOME/.config/chezmoi/key.txt"
    echo
    echo "[IMPORTANT] Back up ~/.config/chezmoi/key.txt to a safe location!"
    echo "[IMPORTANT] Update the 'recipient' field in .chezmoi.yaml with the public key above."
    echo "[IMPORTANT] Encrypted secrets will be skipped until they are re-encrypted for this new key."
    echo
    APPLY_EXCLUDES+=(encrypted)
  fi
fi

# Initialize and apply chezmoi
echo "[INFO] Initializing chezmoi..."
if [[ -n "$LOCAL_SOURCE" ]]; then
  echo "[INFO] Using local source: $LOCAL_SOURCE"
  chezmoi init --source="$LOCAL_SOURCE" "${CHEZMOI_INIT_ARGS[@]}"
  CHEZMOI_SOURCE="$LOCAL_SOURCE"
else
  echo "[INFO] Cloning source over HTTPS: $DOTFILES_REPO_URL"
  chezmoi init "$DOTFILES_REPO_URL" "${CHEZMOI_INIT_ARGS[@]}"
  CHEZMOI_SOURCE="$(chezmoi source-path 2>/dev/null || true)"
  if [[ -n "$CHEZMOI_SOURCE" && -d "$CHEZMOI_SOURCE/.git" ]]; then
    echo "[INFO] Updating chezmoi source: $CHEZMOI_SOURCE"
    git -C "$CHEZMOI_SOURCE" pull --ff-only
  fi
fi

manual_sections=false
if [[ "$SELECTION_MODE" != "full" || ${#WITHOUT_SECTIONS[@]} -gt 0 ]]; then
  manual_sections=true
  APPLY_EXCLUDES+=(scripts)
fi

collect_chezmoi_status
print_chezmoi_dry_run_summary
handle_chezmoi_conflicts

if [[ "$SKIP_CHEZMOI_APPLY" == "false" ]]; then
  echo "[INFO] Applying dotfiles..."
  run_chezmoi_apply
else
  echo "[SKIP] Dotfile apply skipped"
fi

if [[ "$manual_sections" == "true" ]]; then
  echo "[INFO] Running selected install sections..."
  for section in "${SELECTED_SECTIONS[@]}"; do
    run_install_section "$CHEZMOI_SOURCE" "$section"
  done
fi

echo
echo "══════════════════════════════════════════════"
echo "  Bootstrap Complete!"
echo "══════════════════════════════════════════════"
echo
echo "Next steps:"
echo "  1. Restart your shell: exec zsh"
echo "  2. tmux will auto-install plugins on first launch"
echo "  3. Neovim will bootstrap LazyVim on first launch"
echo
