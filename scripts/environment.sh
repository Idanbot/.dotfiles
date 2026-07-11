#!/usr/bin/env bash
# Shared platform detection for bootstrap, section scripts, tests, and doctor.

dotfiles_os_id() {
  if [[ -r /etc/os-release ]]; then
    (
      # shellcheck disable=SC1091
      source /etc/os-release
      printf '%s\n' "${ID:-unknown}"
    )
  else
    printf 'unknown\n'
  fi
}

dotfiles_os_version() {
  if [[ -r /etc/os-release ]]; then
    (
      # shellcheck disable=SC1091
      source /etc/os-release
      printf '%s\n' "${VERSION_ID:-unknown}"
    )
  else
    printf 'unknown\n'
  fi
}

is_wsl() {
  case "${DOTFILES_WSL:-auto}" in
    true | 1 | yes) return 0 ;;
    false | 0 | no) return 1 ;;
    auto) ;;
    *)
      printf 'Invalid DOTFILES_WSL value: %s\n' "$DOTFILES_WSL" >&2
      return 2
      ;;
  esac

  [[ -n "${WSL_DISTRO_NAME:-}" ]] ||
    grep -qi microsoft /proc/sys/kernel/osrelease /proc/version 2>/dev/null
}

is_native() {
  ! is_wsl
}

is_ci() {
  [[ "${DOTFILES_CI:-false}" == "true" || "${CI:-false}" == "true" ]]
}

get_arch() {
  case "$(uname -m)" in
    x86_64) printf 'amd64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    armv7l) printf 'armhf\n' ;;
    *) uname -m ;;
  esac
}

get_platform() {
  if is_wsl; then
    printf '%s-%s-wsl\n' "$(dotfiles_os_id)" "$(dotfiles_os_version)"
  else
    printf '%s-%s-native\n' "$(dotfiles_os_id)" "$(dotfiles_os_version)"
  fi
}

terminal_supports_color() {
  [[ -z "${NO_COLOR:-}" ]] || return 1
  [[ "${TERM:-}" != "dumb" ]] || return 1

  case "${DOTFILES_COLOR:-auto}" in
    always) return 0 ;;
    never) return 1 ;;
    auto) ;;
    *)
      printf 'Invalid DOTFILES_COLOR value: %s\n' "$DOTFILES_COLOR" >&2
      return 2
      ;;
  esac

  [[ -t 1 ]] && return 0
  # Windows Terminal preserves ANSI support for WSL even when a process wrapper
  # makes tty detection unavailable.
  is_wsl && [[ -n "${WT_SESSION:-}" ]]
}

assert_supported_platform() {
  [[ "${DOTFILES_ALLOW_UNSUPPORTED:-0}" == "1" ]] && return 0
  [[ "$(dotfiles_os_id)" == "ubuntu" && "$(dotfiles_os_version)" == "24.04" ]]
}
