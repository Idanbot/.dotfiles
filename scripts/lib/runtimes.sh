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
  if command_exists "$binary" && [[ -z "$(extract_version "$current" || true)" ]] &&
    ! binary_replacement_requested "$binary"; then
    log_warn "Preserving existing $binary with an unknown or timed-out version"
    ((_PRESERVED++)) || true
    return 0
  fi
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
  local decision_id="" decision reason
  case "$binary" in
    git-credential-manager) decision_id=system.git_credential_manager ;;
    nvim) decision_id=editor.neovim ;;
  esac
  if [[ -n "${DOTFILES_VERSION_PLAN:-}" && -n "$decision_id" ]]; then
    decision="$(/usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/install-policy.py" decision \
      --plan "$DOTFILES_VERSION_PLAN" --tool "$decision_id" --target "$target" \
      --active-path "$(command -v "$binary" || true)")" || decision=preserve-stale
    IFS=$'\t' read -r decision reason <<<"$decision"
    case "$decision" in
      noop)
        log_skip "$binary: run-plan no-op; keeping the active installation"
        return 0
        ;;
      preserve | preserve-stale)
        [[ "$decision" != preserve-stale ]] || reason='run-plan inputs changed; start a new run to review them'
        log_warn "Preserving $binary: $reason"
        ((_PRESERVED++)) || true
        return 0
        ;;
    esac
  fi
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

bounded_probe() {
  timeout --kill-after=1 3 "$@" </dev/null
}

observe_version() (
  local executable key cache="" temporary output
  executable="$(command -v "$1")" || return 1
  if [[ -n "${DOTFILES_VERSION_PLAN:-}" ]]; then
    cache="$(dirname "$DOTFILES_VERSION_PLAN")/probe-cache"
    [[ "$(realpath -m -- "$cache")" == "$cache" ]] || return 1
    mkdir -p -- "$cache" || return 1
    chmod 700 "$cache" || return 1
    key="$({
      printf '%s\0' "$@" "$PATH" "$HOME"
      stat -Lc '%d:%i:%s:%y:%z:%a' "$executable"
    } | sha256sum)"
    cache="$cache/${key%% *}"
    if [[ -f "$cache" ]]; then
      cat "$cache"
      return 0
    fi
  fi
  output="$(bounded_probe "$@" 2>&1)" || return 1
  if [[ -n "$cache" ]]; then
    temporary="$(mktemp "${cache}.XXXXXX")" || return 1
    printf '%s\n' "$output" >"$temporary" || return 1
    chmod 600 "$temporary" || return 1
    mv -Tf -- "$temporary" "$cache" || return 1
  fi
  printf '%s\n' "$output"
)

install_github_archive() {
  local binary="$1" repo="$2" requested_version="$3" asset_template="$4" member="$5" checksum_template="$6"
  local version_command="${7:-$binary --version}" tag arch asset checksum_url tmpdir archive current

  tag="$(resolve_tool_version "$repo" "$requested_version")"
  local -a probe
  read -r -a probe <<<"$version_command"
  current="$(observe_version "${probe[@]}" || true)"
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
  local -a probe
  read -r -a probe <<<"$version_command"
  current="$(observe_version "${probe[@]}" || true)"
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

json_boolean_destination_safe() {
  local target="$1" directory
  directory="$(dirname "$target")" || return 1
  [[ "$target" == /* && ! -L "$target" && (! -e "$target" || -f "$target") &&
    "$(realpath -m -- "$directory")" == "$directory" ]]
}

set_json_boolean_preserving() (
  local target="$1" key="$2" value="$3" directory tmp
  umask 077
  [[ "$value" == true || "$value" == false ]] || return 2
  json_boolean_destination_safe "$target" || return 1
  if [[ -e "$target" ]]; then
    [[ -w "$target" ]] || return 1
    jq -e 'type == "object"' "$target" >/dev/null 2>&1 || return 1
  fi

  directory="$(dirname "$target")" || return 1
  mkdir -p -- "$directory" || return 1
  tmp="$(mktemp "${target}.XXXXXX")" || return 1
  trap 'rm -f -- "$tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ -e "$target" ]]; then
    jq --arg key "$key" --argjson value "$value" '.[$key] = $value' \
      "$target" >"$tmp" 2>/dev/null || return 1
  else
    jq -n --arg key "$key" --argjson value "$value" '{($key): $value}' >"$tmp" 2>/dev/null || return 1
  fi
  jq -e 'type == "object"' "$tmp" >/dev/null 2>&1 || return 1
  chmod 600 "$tmp" || return 1
  json_boolean_destination_safe "$target" || return 1
  mv -Tf -- "$tmp" "$target" || return 1
)

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
  managed_operation _omp_install_package "$@"
}

# Native OMP mutates a shared dependency tree and manifest as one manager scope.
omp_plugin_transaction() (
  local package="$1" tool="$2" callback="$3" root target validation temporary committed=false changed=false
  shift 3
  root="${DOTFILES_OMP_PLUGIN_ROOT:-$HOME/.omp/plugins}"
  [[ "$(realpath -m -- "$root")" == "$root" &&
  "$(realpath -m -- "$root/node_modules")" == "$root/node_modules" ]] || return 1
  target="$root/node_modules/$package"
  local path
  for path in "$target" "$root/package.json" "$root/bun.lock" "$root/bun.lockb" "$root/package-lock.json"; do
    [[ ! -L "$path" && "$(realpath -m -- "$(dirname "$path")")" == "$(dirname "$path")" ]] || return 1
  done
  validation="$(omp_plugin_validation_path "$package")"
  temporary="$(mktemp -d "$(managed_state_root)/.omp-transaction.XXXXXX")" || return 1
  cleanup_omp() {
    local status="$?" failed=false
    trap '' HUP INT TERM
    if [[ "$changed" == true && "$committed" == false ]]; then
      restore_publication "$temporary/root" "$root" || failed=true
      restore_publication_metadata "$temporary/package" "$target" || failed=true
      restore_publication "$temporary/validation" "$validation" || failed=true
    fi
    if [[ "$failed" == true ]]; then
      log_error "OMP recovery incomplete for $tool; retain recovery files at $temporary"
      return 1
    fi
    rm -rf -- "$temporary"
    return "$status"
  }
  trap cleanup_omp EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  mkdir "$temporary/root" "$temporary/package" "$temporary/validation" || return 1
  snapshot_publication "$temporary/root" "$root" || return 1
  snapshot_publication "$temporary/package" "$target" false || return 1
  snapshot_publication "$temporary/validation" "$validation" || return 1
  changed=true
  "$callback" "$@" || return 1
  committed=true
)

_omp_install_package() {
  local package="$1" version="$2" tool="$3"
  local root manifest installed_version=""
  root="${DOTFILES_OMP_PLUGIN_ROOT:-$HOME/.omp/plugins}"
  manifest="$root/node_modules/$package/package.json"

  if [[ -e "$root/node_modules/$package" || -L "$root/node_modules/$package" ]] &&
    { [[ -L "$root/node_modules/$package" ||
      "$(realpath -m -- "$(dirname "$manifest")")" != "$(dirname "$manifest")" ]] ||
      ! target_is_owned "$root/node_modules/$package"; }; then
    log_warn "Preserving $tool: existing plugin is unowned or modified; compatibility validation requires a reviewed migration"
    ((_PRESERVED++)) || true
    return 0
  fi

  if [[ -f "$manifest" ]]; then
    installed_version="$(jq -r '.version // empty' "$manifest" 2>/dev/null || true)"
  fi
  if version_equals "$installed_version" "$version" && omp_plugin_is_validated "$package"; then
    log_skip "$tool $version already installed in OMP"
    return 0
  fi

  omp_plugin_transaction "$package" "$tool" _omp_install_candidate "$package" "$version" "$tool" || return 1
  ((_INSTALLED++)) || true
}

_omp_install_candidate() {
  local package="$1" version="$2" tool="$3" root manifest spec installed_version
  root="${DOTFILES_OMP_PLUGIN_ROOT:-$HOME/.omp/plugins}"
  manifest="$root/node_modules/$package/package.json"
  spec="$package@$version"
  assert_owned_target "$root/node_modules/$package" || return 1

  local omp_before omp_after
  omp_before="$(managed_target_digest "$(command -v omp)")" || return 1
  log_info "Installing $tool $version for OMP"
  omp plugin install "$spec" || return 1
  omp_after="$(managed_target_digest "$(command -v omp)")" || return 1
  [[ "$omp_before" == "$omp_after" ]] || {
    log_error "OMP changed during plugin validation; retry before certifying compatibility"
    return 1
  }
  [[ -f "$manifest" ]] || {
    log_error "$tool package manifest was not created at $manifest"
    return 1
  }
  installed_version="$(jq -r '.version // empty' "$manifest")" || return 1
  version_equals "$installed_version" "$version" || {
    log_error "$tool expected version $version, found ${installed_version:-unknown}"
    return 1
  }
  record_install "$tool" "$version" "omp:$package" "$root/node_modules/$package" || return 1
  local validation temporary
  validation="$(omp_plugin_validation_path "$package")"
  temporary="$(mktemp "${validation}.XXXXXX")" || return 1
  omp_plugin_signature "$package" >"$temporary" || {
    rm -f "$temporary"
    return 1
  }
  chmod 600 "$temporary" || return 1
  mv -f -- "$temporary" "$validation" || return 1
  log_success "$tool $version installed for OMP"
}

omp_plugin_validation_path() {
  local key
  key="$(printf '%s\n%s' "${DOTFILES_OMP_PLUGIN_ROOT:-$HOME/.omp/plugins}" "$1" | sha256sum | cut -d' ' -f1)"
  printf '%s/omp-validation-%s.sha256\n' "$(managed_state_root)" "$key"
}

omp_plugin_signature() {
  local executable root
  executable="$(command -v omp)" || return 1
  [[ -f "$executable" ]] || return 1
  root="${DOTFILES_OMP_PLUGIN_ROOT:-$HOME/.omp/plugins}/node_modules"
  [[ -f "$root/$1/package.json" ]] || return 1
  printf '%s\n%s\n%s\n' "$(readlink -f "$executable")" \
    "$(managed_target_digest "$executable")" "$(managed_target_digest "$root")" | sha256sum | cut -d' ' -f1
}

omp_plugin_is_validated() {
  local receipt signature
  receipt="$(omp_plugin_validation_path "$1")"
  [[ -f "$receipt" && ! -L "$receipt" ]] || return 1
  signature="$(omp_plugin_signature "$1")" || return 1
  [[ "$(<"$receipt")" == "$signature" ]]
}

remove_retired_omp_optimizer() {
  managed_operation omp_plugin_transaction @xynogen/pix-optimizer pix-optimizer _remove_retired_omp_optimizer
}

_remove_retired_omp_optimizer() {
  local root="${DOTFILES_OMP_PLUGIN_ROOT:-$HOME/.omp/plugins}"
  local package=@xynogen/pix-optimizer
  [[ "$(realpath -m -- "$root")" == "$root" &&
  "$(realpath -m -- "$root/node_modules")" == "$root/node_modules" ]] || {
    log_error "Preserving redirected OMP plugin directory; review before removing Pix Optimizer"
    return 1
  }
  local declared
  declared="$(/usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/omp-settings.py" "$root/package.json" --has-retired)" || return 1
  if [[ "$declared" == true || -e "$root/node_modules/$package" || -L "$root/node_modules/$package" ]]; then
    log_info "Removing retired Pix Optimizer through OMP"
    omp plugin uninstall "$package" || return 1
    [[ ! -e "$root/node_modules/$package" && ! -L "$root/node_modules/$package" ]] || {
      log_error "OMP did not remove Pix Optimizer; retry its native uninstall"
      return 1
    }
  fi
  declared="$(/usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/omp-settings.py" "$root/package.json" --has-retired)" || return 1
  [[ "$declared" == false ]] || {
    log_error "OMP still declares Pix Optimizer; retirement was not completed"
    return 1
  }
  # Remove only the compatibility override previously introduced by bootstrap.
  /usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/omp-settings.py" \
    "$root/package.json" >/dev/null || return 1
  forget_install pix-optimizer
}

install_github_agent_skill() {
  managed_operation _install_github_agent_skill "$@"
}

_install_github_agent_skill() {
  local skill="$1" repo="$2" version="$3" expected_sha="$4"
  local destination="$HOME/.agents/skills/$skill"
  if [[ -f "$destination/SKILL.md" && ! -L "$destination" &&
    "$(realpath -m -- "$(dirname "$destination")")" == "$(dirname "$destination")" ]]; then
    log_skip "$skill agent skill already exists"
    return 0
  fi
  if [[ -e "$destination" || -L "$destination" ||
    "$(realpath -m -- "$(dirname "$destination")")" != "$(dirname "$destination")" ]]; then
    log_warn "Preserving existing or redirected $skill skill destination; manual migration required"
    return 0
  fi

  _publish_github_agent_skill "$skill" "$repo" "$version" "$expected_sha" || return 1
  ((_INSTALLED++)) || true
  log_success "$skill agent skill $version installed"
}

_publish_github_agent_skill() (
  local skill="$1" repo="$2" version="$3" expected_sha="$4"
  local destination="$HOME/.agents/skills/$skill" tmpdir archive source
  tmpdir="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$tmpdir"' EXIT
  archive="$tmpdir/source.tar.gz"
  log_info "Installing $skill agent skill $version"
  download_verified \
    "https://codeload.github.com/$repo/tar.gz/refs/tags/v$version" \
    "$archive" "sha256:$expected_sha" "$skill-v$version.tar.gz" || return 1
  mkdir -p "$tmpdir/source" || return 1
  tar -xzf "$archive" -C "$tmpdir/source" --strip-components=1 || return 1
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
  install_managed_tree "$source" "$destination" "$skill" "$version" "agent-skill:$repo" - || return 1
)

install_verified_file() {
  managed_operation _install_verified_file "$@"
}

_install_verified_file() {
  local url="$1" destination="$2" checksum="$3" tool="$4" version="$5" owner="$6"
  if ! managed_file_can_update "$destination"; then
    log_warn "Preserving $tool: file is unowned, modified, nonregular, or redirected; manual migration required"
    ((_PRESERVED++)) || true
    return 0
  fi
  if [[ -f "$destination" ]] && sha256_matches "$destination" "$checksum"; then
    log_skip "$tool already verified"
    return 0
  fi
  _publish_verified_file "$url" "$destination" "$checksum" "$tool" "$version" "$owner" || return 1
  ((_INSTALLED++)) || true
  log_success "$tool installed"
}

_publish_verified_file() (
  local url="$1" destination="$2" checksum="$3" tool="$4" version="$5" owner="$6" temporary
  temporary="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$temporary"' EXIT
  download_verified "$url" "$temporary/candidate" "sha256:$checksum" "${destination##*/}" || return 1
  install_managed_file "$temporary/candidate" "$destination" "$tool" "$version" "$owner" 600
)

install_kitty_launcher() {
  managed_operation _install_kitty_launcher "$@"
}

_install_kitty_launcher() {
  local application="$1" name="$2" version="$3" source destination
  [[ "$name" == kitty.desktop || "$name" == kitty-open.desktop ]] || return 2
  source="$application/share/applications/$name"
  destination="$HOME/.local/share/applications/$name"
  [[ -f "$source" ]] || return 0
  if ! managed_file_can_update "$destination"; then
    log_warn "Preserving $name: desktop launcher is unowned, modified, nonregular, or redirected"
    ((_PRESERVED++)) || true
    return 0
  fi
  _publish_kitty_launcher "$source" "$destination" "$application" "$version"
}

_publish_kitty_launcher() (
  local source="$1" destination="$2" application="$3" version="$4" temporary
  temporary="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$temporary"' EXIT
  /usr/bin/python3 - "$source" "$temporary/candidate" "$application" <<'PY' || return 1
import configparser
from pathlib import Path
import sys

source, output, application = sys.argv[1:]
config = configparser.ConfigParser(interpolation=None, strict=False)
config.optionxform = str
with open(source) as stream:
    config.read_file(stream)
binary = str(Path(application) / "bin/kitty").replace("%", "%%")
for char in ("\\", '"', "`", "$"):
    binary = binary.replace(char, "\\" + char)
for section in config.values():
    command = section.get("Exec", "")
    if command == "kitty" or command.startswith("kitty "):
        section["Exec"] = '"' + binary + '"' + command[len("kitty"):]
    if section.get("TryExec") == "kitty":
        section["TryExec"] = str(Path(application) / "bin/kitty")
    if section.get("Icon") == "kitty":
        section["Icon"] = str(Path(application) / "share/icons/hicolor/256x256/apps/kitty.png")
with open(output, "w") as stream:
    config.write(stream)
PY
  install_managed_file "$temporary/candidate" "$destination" kitty-launcher "$version" github:kovidgoyal/kitty 644
)
