#!/usr/bin/env bash
# Internal ownership helpers; source scripts/lib.sh as the public entry point.

managed_operation_lock() {
  local root
  root="$(managed_state_root)"
  ensure_private_directory "$root"
  exec {MANAGED_OPERATION_FD}>"$root/ownership.lock"
  chmod 600 "$root/ownership.lock"
  flock -x "$MANAGED_OPERATION_FD"
}

managed_target_digest() {
  local target="$1"
  if [[ -L "$target" ]]; then
    printf 'symlink:%s\n' "$(readlink -- "$target")" | sha256sum | awk '{print $1}'
  elif [[ -f "$target" ]]; then
    {
      stat -c '%a' "$target"
      sha256sum <"$target"
    } | sha256sum | awk '{print $1}'
  elif [[ -d "$target" ]]; then
    (
      cd "$target" || exit 1
      find . -printf '%p %y %m %l\0' | sort -z
      find . -type f -print0 | sort -z | xargs -0 -r sha256sum --
    ) | sha256sum | awk '{print $1}'
  else
    printf 'absent\n'
  fi
}

ownership_stamp() {
  printf '%s/ownership/%s.sha256\n' "$(managed_state_root)" "$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
}

target_is_owned() {
  local target="$1" stamp
  stamp="$(ownership_stamp "$target")"
  [[ -f "$stamp" && "$(<"$stamp")" == "$(managed_target_digest "$target")" ]] &&
    awk -F '\t' -v target="$target" '$4 == target { found = 1 } END { exit !found }' \
      "$(managed_state_root)/installed.tsv" 2>/dev/null
}

assert_owned_target() {
  local target="$1"
  if [[ "$(realpath -m -- "$(dirname "$target")")" != "$(dirname "$target")" ]]; then
    log_error "Preserving path with redirected or noncanonical ancestors: $target"
    return 1
  fi
  [[ -e "$target" || -L "$target" ]] || return 0
  if ! target_is_owned "$target"; then
    log_error "Preserving unowned or locally modified path: $target; review and move it aside before retrying"
    return 1
  fi
}

install_managed_binary() (
  local src="$1" binary="$2" version="${3:-unknown}" owner="${4:-managed-binary}"
  local bin_dir="${DOTFILES_BIN_DIR:-$HOME/.local/bin}" dest temporary backup="" takeover=false
  local -a smoke
  managed_operation_lock || return 1
  mkdir -p "$bin_dir" || return 1
  dest="$bin_dir/$binary"
  if [[ -f "$dest" && -x "$dest" && ! -L "$dest" ]] && cmp -s "$src" "$dest"; then
    record_install "$binary" "$version" "$owner" "$dest"
    return
  fi
  if binary_replacement_requested "$binary" && [[ -f "$dest" || -L "$dest" ]] &&
    ! target_is_owned "$dest"; then
    [[ "$(realpath -m -- "$bin_dir")" == "$bin_dir" ]] || return 1
    takeover=true
  else
    assert_owned_target "$dest" || return 1
  fi
  temporary="$(mktemp -d "$bin_dir/.dotfiles-binary.XXXXXX")" || return 1
  trap 'rm -rf -- "$temporary"' EXIT
  install -m 0755 "$src" "$temporary/new" || return 1
  [[ -s "$temporary/new" ]] || return 1
  if [[ -n "${5:-}" ]]; then
    read -r -a smoke <<<"$5"
    smoke[0]="$temporary/new"
    "${smoke[@]}" >/dev/null 2>&1 || return 1
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    cp -a -- "$dest" "$temporary/previous" || return 1
  fi
  if [[ "$takeover" == true ]]; then
    backup="$(managed_state_root)/binary-backups/$(date -u '+%Y%m%dT%H%M%S%NZ')-$binary"
    ensure_private_directory "$backup" || return 1
    cp -a -- "$dest" "$backup/$binary" || return 1
    log_warn "Backed up existing $binary to $backup/$binary before approved replacement"
  fi
  mv -Tf -- "$temporary/new" "$dest" || return 1
  if ! record_install "$binary" "$version" "$owner" "$dest"; then
    if [[ -e "$temporary/previous" || -L "$temporary/previous" ]]; then
      mv -Tf -- "$temporary/previous" "$dest"
    else
      rm -f -- "$dest"
    fi
    return 1
  fi
)

install_managed_tree() (
  local source="$1" destination="$2" tool="$3" version="$4" owner="$5" probe="$6" temporary
  shift 6
  managed_operation_lock || return 1
  assert_owned_target "$destination" || return 1
  mkdir -p "$(dirname "$destination")" || return 1
  temporary="$(mktemp -d "$(dirname "$destination")/.dotfiles-tree.XXXXXX")" || return 1
  trap 'rm -rf -- "$temporary"' EXIT
  cp -a -- "$source" "$temporary/new" || return 1
  "$temporary/new/$probe" "$@" >/dev/null 2>&1 || return 1
  if [[ -e "$destination" || -L "$destination" ]]; then
    mv -T -- "$destination" "$temporary/previous" || return 1
  fi
  if ! mv -T -- "$temporary/new" "$destination"; then
    [[ ! -e "$temporary/previous" ]] || mv -T -- "$temporary/previous" "$destination"
    return 1
  fi
  if ! record_install "$tool" "$version" "$owner" "$destination"; then
    rm -rf -- "$destination"
    [[ ! -e "$temporary/previous" ]] || mv -T -- "$temporary/previous" "$destination"
    return 1
  fi
)

# Publish an application and its command links as one rollback-capable operation.
# The probe is a shell function taking the staged application root.
install_managed_app() (
  local source="$1" destination="$2" tool="$3" version="$4" owner="$5" probe="$6"
  shift 6
  local temporary root path stamp index name committed=false changed=false ledger_fd
  local -a paths=("$destination") names=("$tool")
  managed_operation_lock || return 1
  root="$(managed_state_root)"
  for name in "$@"; do
    paths+=("$HOME/.local/bin/$name")
    names+=("$name")
  done
  for path in "${paths[@]}"; do
    assert_owned_target "$path" || return 1
  done
  mkdir -p "$(dirname "$destination")" "$HOME/.local/bin" || return 1
  temporary="$(mktemp -d "$(dirname "$destination")/.dotfiles-app.XXXXXX")" || return 1
  cleanup_app() {
    local rollback_failed=false
    if [[ "$changed" == true && "$committed" == false ]]; then
      for index in "${!paths[@]}"; do
        path="${paths[$index]}"
        rm -rf -- "$path" || rollback_failed=true
        if [[ -e "$temporary/old-$index" || -L "$temporary/old-$index" ]]; then
          cp -a -- "$temporary/old-$index" "$path" || rollback_failed=true
        fi
        stamp="$(ownership_stamp "$path")"
        rm -f -- "$stamp"
        [[ ! -f "$temporary/stamp-$index" ]] || cp -p "$temporary/stamp-$index" "$stamp" || rollback_failed=true
      done
      exec {ledger_fd}>"$root/ledger.lock"
      flock -x "$ledger_fd"
      touch "$root/installed.tsv"
      awk -F '\t' 'NR == FNR { paths[$0] = 1; next } !($4 in paths)' \
        "$temporary/paths" "$root/installed.tsv" >"$temporary/ledger"
      cat "$temporary/records" >>"$temporary/ledger"
      chmod 600 "$temporary/ledger"
      command mv -f "$temporary/ledger" "$root/installed.tsv" || rollback_failed=true
    fi
    if [[ "$rollback_failed" == true ]]; then
      log_error "Rollback incomplete; recovery files retained at $temporary"
      return 1
    fi
    rm -rf -- "$temporary"
  }
  trap cleanup_app EXIT
  cp -a -- "$source" "$temporary/new" || return 1
  "$probe" "$temporary/new" || return 1
  printf '%s\n' "${paths[@]}" >"$temporary/paths"
  touch "$temporary/records"
  for index in "${!paths[@]}"; do
    path="${paths[$index]}"
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a -- "$path" "$temporary/old-$index" || return 1
    fi
    stamp="$(ownership_stamp "$path")"
    [[ ! -f "$stamp" ]] || cp -p "$stamp" "$temporary/stamp-$index" || return 1
    if [[ -f "$root/installed.tsv" ]]; then
      awk -F '\t' -v path="$path" '$4 == path' "$root/installed.tsv" >>"$temporary/records"
    fi
  done
  changed=true
  rm -rf -- "$destination" || return 1
  mv -T -- "$temporary/new" "$destination" || return 1
  for index in "${!paths[@]}"; do
    [[ "$index" != 0 ]] || continue
    ln -s "$destination/bin/${names[$index]}" "$temporary/link-$index" || return 1
    mv -Tf -- "$temporary/link-$index" "${paths[$index]}" || return 1
  done
  "$probe" "$destination" || return 1
  record_install "$tool" "$version" "$owner" "$destination" || return 1
  for index in "${!paths[@]}"; do
    [[ "$index" != 0 ]] || continue
    record_install "${names[$index]}" "$version" symlink "${paths[$index]}" || return 1
  done
  committed=true
)

managed_state_root() {
  printf '%s\n' "${DOTFILES_STATE_DIR:-$HOME/.local/state/dotfiles}"
}

ensure_private_directory() {
  local directory="$1"
  umask 077
  mkdir -p "$directory"
  chmod 700 "$directory"
}

record_install() (
  local tool="$1" version="$2" owner="$3" target="$4"
  local ledger root temporary stamp signature ledger_fd stamp_tmp="" old_stamp=""
  root="$(managed_state_root)"
  ledger="$root/installed.tsv"
  ensure_private_directory "$root"
  exec {ledger_fd}>"$root/ledger.lock"
  chmod 600 "$root/ledger.lock"
  flock -x "$ledger_fd" || return 1
  temporary="$(mktemp "$root/.installed.XXXXXX")" || return 1
  trap 'rm -f -- "$temporary"; [[ -z "$stamp_tmp" ]] || rm -f -- "$stamp_tmp"; [[ -z "$old_stamp" ]] || rm -f -- "$old_stamp"' EXIT
  touch "$ledger"
  awk -F '\t' -v tool="$tool" -v target="$target" \
    '!( $1 == tool && $4 == target )' "$ledger" >"$temporary" || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tool" "$version" "$owner" "$target" "${DOTFILES_SECTION:-unknown}" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$temporary" || return 1
  if [[ "$target" == /* && (-e "$target" || -L "$target") ]]; then
    stamp="$(ownership_stamp "$target")"
    mkdir -p "$(dirname "$stamp")" || return 1
    chmod 700 "$(dirname "$stamp")" || return 1
    signature="$(managed_target_digest "$target")" || return 1
    stamp_tmp="$(mktemp "${stamp}.XXXXXX")" || return 1
    printf '%s\n' "$signature" >"$stamp_tmp" || return 1
    if [[ -f "$stamp" ]]; then
      old_stamp="$(mktemp "${stamp}.previous.XXXXXX")" || return 1
      cp -p -- "$stamp" "$old_stamp" || return 1
    fi
    mv -Tf -- "$stamp_tmp" "$stamp" || return 1
  fi
  if ! mv -Tf -- "$temporary" "$ledger"; then
    if [[ -n "$old_stamp" ]]; then
      mv -Tf -- "$old_stamp" "$stamp"
    elif [[ -n "$stamp_tmp" ]]; then
      rm -f -- "$stamp"
    fi
    return 1
  fi
)

forget_install() (
  local tool="$1" ledger temporary ledger_fd root
  root="$(managed_state_root)"
  ledger="$(managed_state_root)/installed.tsv"
  [[ -f "$ledger" ]] || return 0
  exec {ledger_fd}>"$root/ledger.lock"
  flock -x "$ledger_fd" || return 1
  temporary="$(mktemp "$root/.installed.XXXXXX")" || return 1
  trap 'rm -f -- "$temporary"' EXIT
  awk -F '\t' -v tool="$tool" -v target="${2:-}" '$1 != tool || (target != "" && $4 != target)' "$ledger" >"$temporary" || return 1
  mv "$temporary" "$ledger" || return 1
  chmod 600 "$ledger"
)

managed_link() (
  local target="$1" link="$2" tool="$3" version="$4"
  local temporary
  managed_operation_lock || return 1
  if [[ -f "$link" && -x "$link" && ! -L "$link" && "$(realpath -m -- "$target")" == "$(realpath -m -- "$link")" ]]; then
    log_skip "Preserving existing executable at $link; no self-link needed"
    return 0
  fi
  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    record_install "$tool" "$version" symlink "$link"
    return
  fi
  assert_owned_target "$link" || return 1
  mkdir -p "$(dirname "$link")" || return 1
  temporary="$(mktemp -d "$(dirname "$link")/.dotfiles-link.XXXXXX")" || return 1
  trap 'rm -rf -- "$temporary"' EXIT
  ln -s -- "$target" "$temporary/new" || return 1
  if [[ -e "$link" || -L "$link" ]]; then
    cp -a -- "$link" "$temporary/previous" || return 1
  fi
  mv -Tf -- "$temporary/new" "$link" || return 1
  if ! record_install "$tool" "$version" symlink "$link"; then
    if [[ -e "$temporary/previous" || -L "$temporary/previous" ]]; then
      mv -Tf -- "$temporary/previous" "$link"
    else
      rm -f -- "$link"
    fi
    return 1
  fi
)
