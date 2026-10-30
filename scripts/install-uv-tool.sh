#!/usr/bin/env bash
# Sourced by sections: protect uv's environment, native commands, and receipts.
install_uv_tool() {
  managed_operation _install_uv_tool "$@"
}

_install_uv_tool() {
  local binary="$1" package="$2" version="$3" python="${4:-}"
  if ! manager_scope uv "$package" "$binary"; then
    manager_preserved "$binary" uv 'environment or command bindings could not be verified'
    return 0
  fi
  manager_is_current "$binary" "$version" && return 0
  if ! manager_assert_owned "uv:$package"; then
    manager_preserved "$binary" uv 'environment or command is unowned or locally modified'
    return 0
  fi
  manager_transaction _uv_install_candidate uv "$package" "$binary" "$version" || return 1
  log_success "$binary $version installed"
  ((_INSTALLED++)) || true
}

_uv_install_candidate() {
  local -a arguments=(tool install)
  [[ -z "$python" ]] || arguments+=(-p "$python")
  UV_TOOL_DIR="$MANAGER_ROOT" UV_TOOL_BIN_DIR="$MANAGER_BINS" \
    run_manager uv "${arguments[@]}" "$package==$version" || return 1
  version_ge "$(timeout 15 "$MANAGER_BINS/$binary" --version 2>/dev/null || true)" "$version" || {
    log_error "$binary failed its installed version check"
    return 1
  }
}
