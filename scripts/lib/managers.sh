#!/usr/bin/env bash
# Install and uninstall share package scopes. Mutable ownership is never cached.

declare -Ag _MANAGER_ROOTS=() _MANAGER_BINS=()

manager_directories() {
  local kind="$1" key root bins
  case "$kind" in
    npm)
      MANAGER_ROOT="$(npm_global_prefix)"
      MANAGER_BINS="$MANAGER_ROOT/bin"
      ;;
    omp)
      MANAGER_ROOT="${DOTFILES_OMP_PLUGIN_ROOT:-$HOME/.omp/plugins}"
      MANAGER_BINS="$HOME/.local/bin"
      ;;
    uv | python)
      key="$kind:$HOME:${XDG_DATA_HOME:-}:${XDG_BIN_HOME:-}:${UV_TOOL_DIR:-}:${UV_TOOL_BIN_DIR:-}:${UV_PYTHON_INSTALL_DIR:-}:${UV_PYTHON_BIN_DIR:-}:$(command -v uv)"
      if [[ -z "${_MANAGER_ROOTS[$key]:-}" ]]; then
        if [[ "$kind" == uv ]]; then
          root="$(uv tool dir)" || return 1
          bins="$(uv tool dir --bin)" || return 1
        else
          root="$(uv python dir)" || return 1
          bins="$(uv python dir --bin)" || return 1
        fi
        _MANAGER_ROOTS[$key]="$root" _MANAGER_BINS[$key]="$bins"
      fi
      MANAGER_ROOT="${_MANAGER_ROOTS[$key]}" MANAGER_BINS="${_MANAGER_BINS[$key]}"
      ;;
    *) return 2 ;;
  esac
}

manager_scope() {
  local kind="$1" package="$2" binary="${3:-}" output
  manager_directories "$kind" || return 1
  output="$(/usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/manager-scope.py" \
    "$kind" "$MANAGER_ROOT" "$MANAGER_BINS" "$package" "$binary")" || return 1
  mapfile -t MANAGER_PATHS <<<"$output"
  MANAGER_VERSION="${MANAGER_PATHS[0]}"
  MANAGER_PATHS=("${MANAGER_PATHS[@]:1}")
  MANAGER_TARGET="${MANAGER_PATHS[0]}"
}

manager_assert_owned() {
  local owner="$1" path
  [[ ! -e "$MANAGER_TARGET" ]] || {
    awk -F '\t' -v owner="$owner" -v target="$MANAGER_TARGET" \
      '$3 == owner && $4 == target { found=1 } END { exit !found }' \
      "$(managed_state_root)/installed.tsv" 2>/dev/null || return 1
    target_is_owned "$MANAGER_TARGET" || return 1
  }
  for path in "${MANAGER_PATHS[@]:1}"; do
    # Native bindings derive ownership from the verified receipt/payload. The
    # separately published npm shim must also have its own ownership stamp.
    if [[ "$path" != "$MANAGER_BINS/"* ]]; then
      [[ ! -e "$path" && ! -L "$path" ]] || target_is_owned "$path" || return 1
    fi
  done
}

manager_is_current() {
  local binary="$1" version="$2" active current="$MANAGER_VERSION"
  active="$(command -v "$binary" || true)"
  [[ -n "$active" ]] || return 1
  if [[ -z "$current" || ! -e "$MANAGER_BINS/$binary" || ! "$active" -ef "$MANAGER_BINS/$binary" ]]; then
    current="$(timeout 5 "$binary" --version 2>/dev/null || true)"
  fi
  if [[ ! -e "$MANAGER_BINS/$binary" || ! "$active" -ef "$MANAGER_BINS/$binary" ]] ||
    version_ge "$current" "$version" || [[ -z "$current" ]]; then
    runtime_is_current "$binary" "$version" "$current"
    return
  fi
  return 1
}

manager_transaction() (
  local callback="$1" kind="$2" package="$3" binary="$4" version="$5" temporary path index committed=false
  local -a paths=("${MANAGER_PATHS[@]}")
  local -A saved=()
  for path in "${paths[@]}"; do saved["$path"]=true; done
  temporary="$(mktemp -d "$(managed_state_root)/.manager-transaction.XXXXXX")" || return 1
  printf '%s\n' "${paths[@]}" >"$temporary/targets"
  local bins="$MANAGER_BINS" target="$MANAGER_TARGET"
  [[ ! -d "$bins" ]] || find "$bins" -mindepth 1 -maxdepth 1 -printf '%f\n' >"$temporary/bin-before"
  touch "$temporary/bin-before"
  cleanup_manager() {
    local code="$?" failed=false current
    trap '' HUP INT TERM
    if [[ "$committed" == false ]]; then
      if current="$(/usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/manager-scope.py" \
        "$kind" "$MANAGER_ROOT" "$bins" "$package" --links-only)"; then
        while IFS= read -r path; do
          [[ -n "$path" ]] || continue
          if ! grep -Fxq -- "${path##*/}" "$temporary/bin-before"; then
            rm -f -- "$path" || failed=true
          fi
        done < <(printf '%s\n' "$current" | tail -n +3)
      else
        failed=true
      fi
      for index in "${!paths[@]}"; do
        restore_publication "$temporary/$index" "${paths[$index]}" || failed=true
      done
      if [[ "$failed" == true ]]; then
        log_error "Recovery files retained at $temporary; package rollback incomplete"
        return 1
      fi
    fi
    rm -rf -- "$temporary" || return 1
    return "$code"
  }
  for index in "${!paths[@]}"; do
    mkdir "$temporary/$index" || return 1
    snapshot_publication "$temporary/$index" "${paths[$index]}" || {
      rm -rf -- "$temporary"
      return 1
    }
  done
  trap cleanup_manager EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  "$callback" || return 1
  manager_scope "$kind" "$package" "$binary" || return 1
  if [[ ! -x "$bins/$binary" ]] || { [[ -n "$MANAGER_VERSION" ]] && ! version_equals "$MANAGER_VERSION" "$version"; }; then
    log_error "$binary failed its installed package version check"
    return 1
  fi
  for path in "${MANAGER_PATHS[@]:1}"; do
    if [[ -z "${saved[$path]:-}" ]]; then
      ! grep -Fxq -- "${path##*/}" "$temporary/bin-before" || return 1
      index="${#paths[@]}"
      paths+=("$path")
      printf '%s\n' "$path" >>"$temporary/targets"
      mkdir "$temporary/$index" || return 1
      snapshot_publication "$temporary/$index" "$path" false || return 1
    fi
  done
  if [[ "$kind" == npm ]]; then
    managed_link "$bins/$binary" "$HOME/.local/bin/$binary" "$binary" "$version" || return 1
  fi
  record_install "$binary" "$version" "$kind:$package" "$target" || return 1
  for path in "${MANAGER_PATHS[@]:1}"; do
    [[ "$kind" != npm || "$path" != "$HOME/.local/bin/$binary" ]] || continue
    record_install "$binary" "$version" "$kind:$package" "$path" || return 1
  done
  committed=true
)
