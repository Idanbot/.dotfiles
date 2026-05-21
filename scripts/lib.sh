#!/usr/bin/env bash
# lib.sh — Shared utility library for dotfiles install scripts
# Sourced by all .chezmoiscripts/run_once_* and run_onchange_* scripts

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m' # No Color

# ── Counters ──────────────────────────────────────────────────────────────────
_INSTALLED=0
_SKIPPED=0
_FAILED=0
_WARNINGS=0

# ── Logging ───────────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; ((_WARNINGS++)) || true; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; ((_FAILED++)) || true; }
log_skip()    { echo -e "${DIM}[SKIP]${NC}  $*"; ((_SKIPPED++)) || true; }
log_step()    { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

# ── Environment Detection ─────────────────────────────────────────────────────
is_wsl() {
  grep -qi microsoft /proc/version 2>/dev/null
}

is_native() {
  ! is_wsl
}

is_ci() {
  [[ "${DOTFILES_CI:-false}" == "true" ]]
}

# Override WSL detection in CI
if [[ "${DOTFILES_WSL:-}" == "true" ]]; then
  is_wsl() { return 0; }
  is_native() { return 1; }
elif [[ "${DOTFILES_WSL:-}" == "false" ]]; then
  is_wsl() { return 1; }
  is_native() { return 0; }
fi

get_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l)  echo "armhf" ;;
    *)       echo "$arch" ;;
  esac
}

# ── Idempotency Helpers ───────────────────────────────────────────────────────
is_installed() {
  command -v "$1" &>/dev/null
}

install_if_missing() {
  local cmd="$1"
  shift
  if is_installed "$cmd"; then
    log_skip "$cmd already installed"
    return 0
  fi
  log_info "Installing $cmd..."
  if "$@"; then
    log_success "$cmd installed"
    ((_INSTALLED++)) || true
  else
    log_error "Failed to install $cmd"
    return 1
  fi
}

# ── Package Management ────────────────────────────────────────────────────────
apt_install() {
  local packages=("$@")
  local to_install=()
  for pkg in "${packages[@]}"; do
    if dpkg -s "$pkg" &>/dev/null; then
      log_skip "$pkg (apt) already installed"
    else
      to_install+=("$pkg")
    fi
  done
  if [[ ${#to_install[@]} -gt 0 ]]; then
    log_info "Installing apt packages: ${to_install[*]}"
    sudo apt-get install -y "${to_install[@]}"
    for pkg in "${to_install[@]}"; do
      log_success "$pkg installed"
      ((_INSTALLED++)) || true
    done
  fi
}

# ── sudo helper ───────────────────────────────────────────────────────────────
require_sudo() {
  if ! sudo -n true 2>/dev/null; then
    log_info "Sudo access required. Please enter your password."
    sudo -v
  fi
  # Keep sudo alive in background
  while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null &
}

# ── Download Helpers ──────────────────────────────────────────────────────────
download() {
  local url="$1" dest="$2"
  if is_installed curl; then
    curl -fsSL -o "$dest" "$url"
  elif is_installed wget; then
    wget -qO "$dest" "$url"
  else
    log_error "Neither curl nor wget found"
    return 1
  fi
}

# ── GitHub Release Helper ─────────────────────────────────────────────────────
github_latest_release() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | grep -oP '"tag_name": "\K[^"]+'
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  local script_name="${1:-$(basename "$0")}"
  echo -e "\n${BOLD}── Summary: ${script_name} ──${NC}"
  echo -e "  ${GREEN}Installed:${NC} ${_INSTALLED}"
  echo -e "  ${DIM}Skipped:${NC}   ${_SKIPPED}"
  echo -e "  ${YELLOW}Warnings:${NC}  ${_WARNINGS}"
  echo -e "  ${RED}Failed:${NC}    ${_FAILED}"
  if [[ $_FAILED -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}Some installations failed!${NC}"
    return 1
  fi
}
