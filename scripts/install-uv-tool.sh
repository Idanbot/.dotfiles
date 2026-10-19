#!/usr/bin/env bash
# Sourced by sections: protect both uv's environment and its published command.
install_uv_tool() (
  local binary="$1" package="$2" version="$3" python="${4:-}"
  local target command_path
  runtime_is_current "$binary" "$version" "$("$binary" --version 2>/dev/null || true)" && return 0
  target="$(uv tool dir)/$package"
  command_path="${UV_TOOL_BIN_DIR:-$HOME/.local/bin}/$binary"
  managed_operation_lock || return 1
  # Preflight is advisory. Recheck after acquiring the mutation lock as well.
  runtime_is_current "$binary" "$version" "$("$binary" --version 2>/dev/null || true)" && return 0
  if ! assert_owned_target "$target" || ! assert_owned_target "$command_path"; then
    log_warn "Preserving $binary: uv environment or command is unowned or locally modified"
    return 0
  fi
  local arguments=(tool install --force)
  [[ -z "$python" ]] || arguments+=(-p "$python")
  uv "${arguments[@]}" "$package==$version" || return 1
  version_ge "$("$command_path" --version 2>/dev/null || true)" "$version" || {
    log_error "$binary failed its installed version check"
    return 1
  }
  record_install "$binary" "$version" "uv:$package" "$target" || return 1
  record_install "$binary" "$version" "uv:$package" "$command_path" || return 1
  log_success "$binary $version installed"
)
