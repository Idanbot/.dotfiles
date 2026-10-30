#!/usr/bin/env bash
# Serialize configuration mutations; bootstrap delegates its live lock to children.

state_lock_delegated() {
  local root="$1" owner="${DOTFILES_LOCK_OWNER_PID:-}" helper="${DOTFILES_LOCK_HELPER_PID:-}" parent
  [[ "$owner" =~ ^[1-9][0-9]*$ && "$helper" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -f "$root/.bootstrap-lock-ready-$owner" &&
    "/proc/$helper/fd/9" -ef "$root/bootstrap.lock" ]] || return 1
  [[ "$(awk '/^PPid:/ {print $2}' "/proc/$helper/status" 2>/dev/null)" == "$owner" ]] || return 1
  parent="$BASHPID"
  while [[ "$parent" =~ ^[1-9][0-9]*$ && "$parent" != 1 ]]; do
    [[ "$parent" != "$owner" ]] || return 0
    parent="$(awk '/^PPid:/ {print $2}' "/proc/$parent/status" 2>/dev/null)" || return 1
  done
  return 1
}

state_operation_lock() {
  local root="$1" timeout="${DOTFILES_LOCK_TIMEOUT:-0}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || {
    printf 'Invalid lock timeout\n' >&2
    return 2
  }
  state_lock_delegated "$root" && return 0
  if [[ -n "${STATE_OPERATION_FD:-}" && "/proc/$BASHPID/fd/$STATE_OPERATION_FD" -ef "$root/bootstrap.lock" ]]; then
    return 0
  fi
  umask 077
  mkdir -p "$root" || return 1
  chmod 700 "$root" || return 1
  exec {STATE_OPERATION_FD}>>"$root/bootstrap.lock"
  chmod 600 "$root/bootstrap.lock"
  if ! flock -w "$timeout" "$STATE_OPERATION_FD"; then
    printf 'Dotfiles state lock is busy; retry or set DOTFILES_LOCK_TIMEOUT (lock: %s/bootstrap.lock)\n' "$root" >&2
    return 75
  fi
}

state_operation_unlock() {
  [[ -z "${STATE_OPERATION_FD:-}" ]] || exec {STATE_OPERATION_FD}>&-
  unset STATE_OPERATION_FD
}
