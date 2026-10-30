#!/usr/bin/env bash
# Internal runtimes helpers; source scripts/lib.sh as the public entry point.

resolve_tool_version() {
  local repo="$1" requested="${2:-latest}"
  if [[ -z "$requested" || "$requested" == "latest" ]]; then
    github_latest_release "$repo"
  else
    printf '%s\n' "$requested"
  fi
}

version_without_v() { printf '%s\n' "${1#v}"; }

extract_version() {
  local value="${1#v}"
  # lazygit emits commit/build metadata before its actual version field.
  if [[ "$value" =~ version=([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi
  grep -oE '[0-9]+([.][0-9]+){0,3}([+-][0-9A-Za-z._-]+)?' <<<"$value" | head -1
}

version_compare() {
  local left right ordered
  left="$(extract_version "${1:-}")"
  right="$(extract_version "${2:-}")"
  [[ -n "$left" && -n "$right" ]] || return 2
  if [[ "$left" == "$right" ]]; then
    printf '0\n'
  else
    # Native Python metadata normalizes date versions such as 2026.08.19.
    ordered="$(printf '%s\n%s\n' "$left" "$right" | LC_ALL=C sort -Vu)"
    if [[ "$ordered" != *$'\n'* ]]; then
      printf '0\n'
    elif [[ "${ordered%%$'\n'*}" == "$left" ]]; then
      printf '%s\n' -1
    else
      printf '1\n'
    fi
  fi
}

version_equals() { [[ "$(version_compare "$1" "$2" 2>/dev/null || printf x)" == 0 ]]; }
version_ge() {
  local result
  result="$(version_compare "$1" "$2" 2>/dev/null || printf x)"
  [[ "$result" == 0 || "$result" == 1 ]]
}
version_major_matches() {
  local current expected
  current="$(extract_version "${1:-}")"
  expected="$(extract_version "${2:-}")"
  [[ -n "$current" && -n "$expected" && "${current%%.*}" == "${expected%%.*}" ]]
}

github_asset_name() {
  local template="$1" tag="$2" arch="$3" version
  version="$(version_without_v "$tag")"
  template="${template//\{tag\}/$tag}"
  template="${template//\{version\}/$version}"
  template="${template//\{arch\}/$arch}"
  printf '%s\n' "$template"
}

binary_replacement_requested() {
  [[ ",${DOTFILES_REPLACE_BINARIES:-}," == *",$1,"* ]]
}

replacement_supported() {
  PYTHONPATH="$DOTFILES_SOURCE_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}" \
    /usr/bin/python3 -B -m dotfiles.replacements "$1" "${2:-auto}"
}

runtime_activation_ready() {
  [[ "$1" == java ]] || return 0
  local pointer="$HOME/.local/share/dotfiles/tools/java/current"
  [[ -e "$pointer" || -L "$pointer" ]] || return 0
  [[ "$(realpath -m -- "$(dirname "$pointer")")" == "$(dirname "$pointer")" ]] && target_is_owned "$pointer"
}

preserve_existing_release_binary() {
  local binary="$1" current="$2" target="${DOTFILES_BIN_DIR:-$HOME/.local/bin}/$1"
  if ! runtime_activation_ready "$binary"; then
    log_warn "Preserving $binary: activation pointer is unowned or modified; manual migration required before an upgrade"
    ((_PRESERVED++)) || true
    return 0
  fi
  # Policy-managed runs must not shadow an executable owned by another installer.
  if [[ -n "${DOTFILES_VERSION_PLAN:-}" ]] && command_exists "$binary"; then
    target="$(command -v "$binary")"
    if [[ "$binary" == aws ]] && target_is_owned /usr/local/aws-cli; then
      return 1
    fi
    if [[ ! -f "$target" || ! -x "$target" ]]; then
      log_warn "Preserving unowned $binary at $target; update skipped"
      ((_PRESERVED++)) || true
      return 0
    fi
  fi
  [[ -e "$target" || -L "$target" ]] || return 1
  target_is_owned "$target" && return 1
  local package
  package="$(dpkg-query -S "$(readlink -f -- "$target")" 2>/dev/null | head -1 || true)"
  if [[ -n "$package" ]]; then
    log_warn "Preserving package-managed $binary at $target (${package%%: /*}); repository version is advisory"
    log_info "Update $binary through its package manager; binary replacement is not appropriate for this path"
    ((_PRESERVED++)) || true
    return 0
  fi
  if binary_replacement_requested "$binary"; then
    if replacement_supported "$binary" 2>/dev/null; then
      return 1
    fi
    log_warn "Preserving $binary: named takeover is unsupported for this backend; manual migration required"
    ((_PRESERVED++)) || true
    return 0
  fi
  [[ -f "$target" && -x "$target" ]] || return 1
  [[ -n "${DOTFILES_VERSION_PLAN:-}" || -n "$(extract_version "$current")" ]] || return 1
  local reason='unowned or modified'
  if [[ -f "$(managed_state_root)/installed.tsv" ]] &&
    awk -F '\t' -v target="$target" '$4 == target { found = 1 } END { exit !found }' "$(managed_state_root)/installed.tsv" &&
    [[ ! -f "$(ownership_stamp "$target")" ]]; then
    reason='legacy installation without an ownership stamp'
  fi
  log_warn "Preserving existing $binary (${current%%$'\n'*}) at $target; upgrade skipped: $reason"
  if replacement_supported "$binary" 2>/dev/null; then
    log_info "To back it up and replace only this binary, rerun with DOTFILES_REPLACE_BINARIES=$binary"
  else
    log_info "Named takeover is unsupported for $binary's backend; review a manual migration"
  fi
  ((_PRESERVED++)) || true
  return 0
}

runtime_is_current() {
  local binary="$1" target="$2" current="$3"
  if command_exists "$binary" && [[ -z "$(extract_version "$current" || true)" ]]; then
    if binary_replacement_requested "$binary" && replacement_supported "$binary" 2>/dev/null && runtime_activation_ready "$binary"; then
      return 1
    fi
    log_warn "Preserving existing $binary with an unknown version; update skipped (unsupported named takeovers require manual migration)"
    ((_PRESERVED++)) || true
    return 0
  fi
  if command_exists "$binary" && version_ge "$current" "$target"; then
    if version_equals "$current" "$target"; then
      log_skip "$binary $(extract_version "$current") matches repository $target"
    else
      log_skip "$binary $(extract_version "$current") is newer than repository $target; preserving current runtime"
    fi
    return 0
  fi
  preserve_existing_release_binary "$binary" "$current"
}

install_github_archive() {
  local binary="$1" repo="$2" requested_version="$3" asset_template="$4" member="$5" checksum_template="$6"
  local version_command="${7:-$binary --version}" tag arch asset checksum_url tmpdir archive current

  tag="$(resolve_tool_version "$repo" "$requested_version")"
  current="$(bash -c "$version_command" 2>/dev/null || true)"
  if is_installed "$binary" && version_ge "$current" "$tag"; then
    log_skip "$binary $tag already installed or newer"
    return 0
  fi

  preserve_existing_release_binary "$binary" "$current" && return 0

  arch="$(get_arch)"
  asset="$(github_asset_name "$asset_template" "$tag" "$arch")"
  member_path="$(github_asset_name "$member" "$tag" "$arch")"
  checksum_url="$(github_asset_name "$checksum_template" "$tag" "$arch")"
  tmpdir="$(mktemp -d)"
  archive="$tmpdir/$asset"
  log_info "Installing $binary from $repo $tag"
  download_verified \
    "https://github.com/${repo}/releases/download/${tag}/${asset}" \
    "$archive" "$checksum_url" "$asset"
  case "$archive" in
    *.zip)
      unzip -q "$archive" -d "$tmpdir"
      ;;
    *)
      tar -xf "$archive" -C "$tmpdir" "$member_path"
      ;;
  esac
  install_managed_binary "$tmpdir/$member_path" "$binary" "${tag#v}" "github:$repo" "$version_command"
  rm -rf "$tmpdir"
  log_success "$binary $tag installed"
  if [[ -n "$current" ]]; then
    ((_UPGRADED++)) || true
  else
    ((_INSTALLED++)) || true
  fi
}

install_github_binary() {
  local binary="$1" repo="$2" requested_version="$3" asset_template="$4" output_name="$5" checksum_template="$6"
  local version_command="${7:-$binary --version}" tag arch asset checksum_url tmpdir dest current

  tag="$(resolve_tool_version "$repo" "$requested_version")"
  current="$(bash -c "$version_command" 2>/dev/null || true)"
  if is_installed "$binary" && version_ge "$current" "$tag"; then
    log_skip "$binary $tag already installed or newer"
    return 0
  fi

  preserve_existing_release_binary "$binary" "$current" && return 0

  arch="$(get_arch)"
  asset="$(github_asset_name "$asset_template" "$tag" "$arch")"
  checksum_url="$(github_asset_name "$checksum_template" "$tag" "$arch")"
  tmpdir="$(mktemp -d)"
  dest="$tmpdir/$output_name"
  log_info "Installing $binary from $repo $tag"
  download_verified \
    "https://github.com/${repo}/releases/download/${tag}/${asset}" \
    "$dest" "$checksum_url" "$asset"
  install_managed_binary "$dest" "$binary" "${tag#v}" "github:$repo" "$version_command"
  rm -rf "$tmpdir"
  log_success "$binary $tag installed"
  if [[ -n "$current" ]]; then
    ((_UPGRADED++)) || true
  else
    ((_INSTALLED++)) || true
  fi
}

set_json_boolean_preserving() {
  local target="$1" key="$2" value="$3" directory tmp
  [[ "$value" == true || "$value" == false ]] || return 2
  [[ ! -L "$target" ]] || return 1
  [[ ! -e "$target" || -f "$target" ]] || return 1
  [[ ! -s "$target" ]] || jq empty "$target" >/dev/null 2>&1 || return 1

  directory="$(dirname "$target")"
  ensure_private_directory "$directory"
  tmp="$(mktemp "${target}.XXXXXX")"
  if [[ -s "$target" ]]; then
    jq --arg key "$key" --argjson value "$value" '.[$key] = $value' \
      "$target" >"$tmp"
  else
    jq -n --arg key "$key" --argjson value "$value" '{($key): $value}' >"$tmp"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$target"
}

nerd_font_files_present() {
  local name="$1" directory="${2:-$HOME/.local/share/fonts/$1}"
  [[ -d "$directory" ]] || return 1
  find "$directory" -maxdepth 1 -type f -size +0 \
    \( -iname "${name}NerdFont*.otf" -o -iname "${name}NerdFont*.ttf" \) \
    -print -quit 2>/dev/null | grep -q .
}

nerd_font_registered() {
  local name="$1"
  command_exists fc-list &&
    fc-list 2>/dev/null | grep -Fi "${name} Nerd Font" >/dev/null
}

npm_global_prefix() {
  printf '%s\n' "${DOTFILES_NPM_PREFIX:-$HOME/.local/share/npm}"
}

append_runtime_paths() {
  local directory
  for directory in "$@"; do
    case ":$PATH:" in
      *":$directory:"*) ;;
      *) PATH="${PATH:+$PATH:}$directory" ;;
    esac
  done
  export PATH
}

activate_node_paths() {
  local prefix
  prefix="$(npm_global_prefix)"
  append_runtime_paths "$HOME/.local/bin" "$prefix/bin"
}

npm_install_global() {
  managed_operation _npm_install_global "$@"
}

_npm_install_global() {
  local package="$1" version="$2" binary="$3" allow_scripts="${4:-}"
  activate_node_paths
  if ! manager_scope npm "$package" "$binary"; then
    manager_preserved "$binary" npm 'package scope or command bindings could not be verified'
    return 0
  fi
  manager_is_current "$binary" "$version" && return 0
  if ! manager_assert_owned "npm:$package"; then
    manager_preserved "$binary" npm 'package or published command is unowned or locally modified'
    return 0
  fi
  manager_transaction _npm_install_candidate npm "$package" "$binary" "$version" || return 1
  log_success "$binary $version installed"
  ((_INSTALLED++)) || true
}

_npm_install_candidate() {
  local -a arguments=(install --global --prefix "$MANAGER_ROOT" --no-audit --no-fund)
  [[ -z "$allow_scripts" ]] || arguments+=("--allow-scripts=$allow_scripts")
  run_manager npm "${arguments[@]}" "$package@$version"
}

omp_install_package() {
  local package="$1" version="$2" tool="$3"
  local root manifest installed_version="" spec policy_changed=unchanged
  root="${DOTFILES_OMP_PLUGIN_ROOT:-$HOME/.omp/plugins}"
  manifest="$root/node_modules/$package/package.json"
  spec="${package}@${version}"

  if [[ "$package" == @xynogen/pix-optimizer ]]; then
    policy_changed="$(/usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/omp-settings.py" \
      plugins "$root/package.json" \
      --overrides "$(package_metadata ai_tools pix_optimizer dependency_overrides)")" || return 1
    initialize_pix_optimizer_state || return 1
  fi

  if [[ -f "$manifest" ]]; then
    installed_version="$(jq -r '.version // empty' "$manifest" 2>/dev/null || true)"
  fi
  if version_equals "$installed_version" "$version" && [[ "$policy_changed" == unchanged ]]; then
    log_skip "$tool $version already installed in OMP"
    return 0
  fi

  log_info "Installing $tool $version for OMP"
  omp plugin install "$spec" || return 1
  [[ -f "$manifest" ]] || {
    log_error "$tool package manifest was not created at $manifest"
    return 1
  }
  installed_version="$(jq -r '.version // empty' "$manifest")"
  version_equals "$installed_version" "$version" || {
    log_error "$tool expected version $version, found ${installed_version:-unknown}"
    return 1
  }
  record_install "$tool" "$version" "omp:$package" "$root/node_modules/$package"
  ((_INSTALLED++)) || true
  log_success "$tool $version installed for OMP"
}

initialize_pix_optimizer_state() {
  local directory="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
  /usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/omp-settings.py" \
    optimizer "$directory/pix.json" --legacy "$HOME/.omp/agent/optimizer.json" >/dev/null
}

install_github_agent_skill() {
  local skill="$1" repo="$2" version="$3" expected_sha="$4"
  local destination="$HOME/.agents/skills/$skill" tmpdir archive source
  if [[ -f "$destination/SKILL.md" ]]; then
    log_skip "$skill agent skill already exists"
    return 0
  fi

  tmpdir="$(mktemp -d)"
  archive="$tmpdir/source.tar.gz"
  log_info "Installing $skill agent skill $version"
  download_verified \
    "https://codeload.github.com/$repo/tar.gz/refs/tags/v$version" \
    "$archive" "sha256:$expected_sha" "$skill-v$version.tar.gz"
  mkdir -p "$tmpdir/source"
  tar -xzf "$archive" -C "$tmpdir/source" --strip-components=1
  source="$tmpdir/source/skills/$skill"
  [[ -f "$source/SKILL.md" ]] || {
    rm -rf "$tmpdir"
    log_error "$skill archive does not contain skills/$skill/SKILL.md"
    return 1
  }
  [[ ! -e "$destination" || -d "$destination" ]] || {
    rm -rf "$tmpdir"
    log_error "$skill destination exists and is not a directory: $destination"
    return 1
  }
  mkdir -p "$destination"
  cp -a "$source/." "$destination/"
  rm -rf "$tmpdir"
  record_install "$skill" "$version" "agent-skill:$repo" "$destination"
  ((_INSTALLED++)) || true
  log_success "$skill agent skill $version installed"
}
