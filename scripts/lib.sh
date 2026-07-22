#!/usr/bin/env bash
# Shared, secret-safe utility library for all install sections.

set -euo pipefail

DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/environment.sh
source "$DOTFILES_SOURCE_DIR/scripts/environment.sh"
export PATH="$HOME/.local/bin:$HOME/.local/share/npm/bin:$HOME/.cargo/bin:$HOME/.fzf/bin:/usr/local/go/bin:$PATH"

if terminal_supports_color; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
  BOLD=""
  DIM=""
  NC=""
fi

_INSTALLED=0
_SKIPPED=0
_FAILED=0
_WARNINGS=0
_SUDO_KEEPALIVE_PID=""

timestamp() { date '+%H:%M:%S'; }

json_escape() {
  local value="${1:-}"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

emit_event() {
  local level="$1"
  shift
  [[ -n "${DOTFILES_EVENT_LOG:-}" ]] || return 0
  umask 077
  mkdir -p "$(dirname "$DOTFILES_EVENT_LOG")"
  printf '{"time":"%s","run_id":"%s","section":"%s","level":"%s","message":"%s"}\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$(json_escape "${DOTFILES_RUN_ID:-unknown}")" \
    "$(json_escape "${DOTFILES_SECTION:-bootstrap}")" \
    "$(json_escape "$level")" \
    "$(json_escape "$*")" >>"$DOTFILES_EVENT_LOG"
  chmod 600 "$DOTFILES_EVENT_LOG"
}

log_line() {
  local level="$1" color="$2" spacing="$3"
  shift 3
  printf '%s %b[%s]%b%s%s\n' "$(timestamp)" "$color" "$level" "$NC" "$spacing" "$*"
  emit_event "${level,,}" "$*"
}

log_info() { log_line INFO "$BLUE" "  " "$*"; }
log_success() {
  log_line OK "$GREEN" "    " "$*"
}
log_warn() {
  log_line WARN "$YELLOW" "  " "$*"
  ((_WARNINGS++)) || true
}
log_error() {
  log_line ERROR "$RED" " " "$*" >&2
  ((_FAILED++)) || true
}
log_skip() {
  log_line SKIP "$DIM" "  " "$*"
  ((_SKIPPED++)) || true
}
log_step() {
  printf '\n%b== %s ==%b\n' "$BOLD$CYAN" "$*" "$NC"
  emit_event step "$*"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }
is_installed() { command_exists "$1"; }

cleanup_sudo_keepalive() {
  if [[ -n "${_SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    _SUDO_KEEPALIVE_PID=""
  fi
}

require_sudo() {
  if ! sudo -n true 2>/dev/null; then
    log_info "Sudo access is required for system packages"
    sudo -v
  fi
  if [[ -z "${_SUDO_KEEPALIVE_PID:-}" ]]; then
    (
      while kill -0 "$PPID" 2>/dev/null; do
        sudo -n true 2>/dev/null || exit 0
        sleep 45
      done
    ) &
    _SUDO_KEEPALIVE_PID=$!
    trap cleanup_sudo_keepalive EXIT
  fi
}

apt_env() {
  sudo env \
    DEBIAN_FRONTEND=noninteractive \
    NEEDRESTART_MODE=a \
    UCF_FORCE_CONFFOLD=1 \
    "$@"
}

apt_update() {
  apt_env apt-get -o Acquire::Retries=3 -qq update
}

apt_install() {
  local packages=("$@") to_install=() pkg
  for pkg in "${packages[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -Fq 'install ok installed'; then
      log_skip "$pkg (apt) already installed"
    else
      to_install+=("$pkg")
    fi
  done

  if [[ ${#to_install[@]} -eq 0 ]]; then
    return 0
  fi

  log_info "Installing apt packages: ${to_install[*]}"
  apt_env apt-get \
    -o Acquire::Retries=3 \
    -o Dpkg::Options::=--force-confold \
    -y --no-install-recommends install "${to_install[@]}"
  for pkg in "${to_install[@]}"; do
    log_success "$pkg installed"
    record_install "$pkg" "$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || printf unknown)" apt "$pkg"
    ((_INSTALLED++)) || true
  done
}

install_apt_key() {
  local url="$1" destination="$2" expected_fingerprint="$3"
  local armored actual tmp
  tmp="$(mktemp -d)"
  armored="$tmp/key.asc"
  download "$url" "$armored"
  actual="$(gpg --show-keys --with-colons "$armored" 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')"
  if [[ "${actual^^}" != "${expected_fingerprint// /}" ]]; then
    rm -rf "$tmp"
    log_error "APT signing key fingerprint mismatch for $url"
    return 1
  fi
  gpg --dearmor <"$armored" >"$tmp/key.gpg"
  sudo install -m 0644 "$tmp/key.gpg" "$destination"
  rm -rf "$tmp"
  log_success "Verified APT signing key ${actual: -16}"
}

install_if_missing() {
  local cmd="$1"
  shift
  if is_installed "$cmd"; then
    log_skip "$cmd already installed"
    return 0
  fi
  log_info "Installing $cmd"
  if "$@"; then
    log_success "$cmd installed"
    ((_INSTALLED++)) || true
  else
    log_error "Failed to install $cmd"
    return 1
  fi
}

download() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if command_exists curl; then
    curl --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors -fsSLo "$dest" "$url"
  elif command_exists wget; then
    wget --https-only --tries=3 -qO "$dest" "$url"
  else
    log_error "curl or wget is required to download $url"
    return 1
  fi
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

checksum_for_asset() {
  local checksums="$1" asset="$2"
  awk -v asset="$asset" '
    {
      hash = $1
      if (NF == 1 && hash ~ /^[0-9a-fA-F]{64}$/) {
        print hash
        exit
      }
      name = $2
      sub(/^\*/, "", name)
      sub(/^\.\//, "", name)
      if (name == asset || name ~ ("/" asset "$") || $0 ~ ("[[:space:]]" asset "$") ) {
        print hash
        exit
      }
    }
  ' "$checksums"
}

go_checksum_from_index() {
  local index_file="$1" asset="$2" checksum
  command -v jq >/dev/null 2>&1 || return 127
  checksum="$(
    jq -er --arg asset "$asset" \
      '[.[] | .files[] | select(.filename == $asset) | .sha256][0] // empty' \
      "$index_file" 2>/dev/null
  )" || return 1
  [[ "$checksum" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s\n' "$checksum"
}

go_release_checksum() {
  local asset="$1" index_file checksum
  index_file="$(mktemp)"
  if ! download 'https://go.dev/dl/?mode=json&include=all' "$index_file"; then
    rm -f "$index_file"
    return 1
  fi
  if ! checksum="$(go_checksum_from_index "$index_file" "$asset")"; then
    rm -f "$index_file"
    log_error "No checksum found in the Go release index for $asset"
    return 1
  fi
  rm -f "$index_file"
  printf '%s\n' "$checksum"
}

verify_sha256() {
  local file="$1" expected="$2" actual
  actual="$(sha256_file "$file")"
  if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
    log_error "Invalid SHA256 declaration for $(basename "$file")"
    return 1
  fi
  if [[ "${actual,,}" != "${expected,,}" ]]; then
    log_error "Checksum mismatch for $(basename "$file"): expected $expected, got $actual"
    return 1
  fi
  log_success "Verified SHA256 for $(basename "$file")"
}

download_verified() {
  local url="$1" dest="$2" checksum_spec="$3" checksum_name
  local expected checksum_file
  checksum_name="${4:-$(basename "$dest")}"
  download "$url" "$dest"

  case "$checksum_spec" in
    sha256:*)
      expected="${checksum_spec#sha256:}"
      ;;
    https://*)
      checksum_file="$(mktemp)"
      download "$checksum_spec" "$checksum_file"
      expected="$(checksum_for_asset "$checksum_file" "$checksum_name")"
      rm -f "$checksum_file"
      ;;
    *)
      log_error "Unverified download blocked: $url"
      rm -f "$dest"
      return 1
      ;;
  esac

  if [[ -z "$expected" ]]; then
    log_error "No checksum found for $checksum_name"
    rm -f "$dest"
    return 1
  fi
  verify_sha256 "$dest" "$expected"
}

github_latest_release() {
  local repo="$1"
  curl --proto '=https' --tlsv1.2 --retry 3 -fsSL \
    "https://api.github.com/repos/${repo}/releases/latest" |
    sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -1
}

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
  grep -oE '[0-9]+([.][0-9]+){0,3}([+-][0-9A-Za-z._-]+)?' <<<"$value" | head -1
}

version_compare() {
  local left right
  left="$(extract_version "${1:-}")"
  right="$(extract_version "${2:-}")"
  [[ -n "$left" && -n "$right" ]] || return 2
  if [[ "$left" == "$right" ]]; then
    printf '0\n'
  elif [[ "$(printf '%s\n%s\n' "$left" "$right" | sort -V | head -1)" == "$left" ]]; then
    printf '%s\n' -1
  else
    printf '1\n'
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

install_managed_binary() {
  local src="$1" binary="$2" version="${3:-unknown}" owner="${4:-managed-binary}"
  local bin_dir="${DOTFILES_BIN_DIR:-$HOME/.local/bin}" dest
  mkdir -p "$bin_dir"
  dest="$bin_dir/$binary"
  install -m 0755 "$src" "$dest"
  record_install "$binary" "$version" "$owner" "$dest"
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
  tar -xf "$archive" -C "$tmpdir" "$member_path"
  install_managed_binary "$tmpdir/$member_path" "$binary" "${tag#v}" "github:$repo"
  rm -rf "$tmpdir"
  log_success "$binary $tag installed"
  ((_INSTALLED++)) || true
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

  arch="$(get_arch)"
  asset="$(github_asset_name "$asset_template" "$tag" "$arch")"
  checksum_url="$(github_asset_name "$checksum_template" "$tag" "$arch")"
  tmpdir="$(mktemp -d)"
  dest="$tmpdir/$output_name"
  log_info "Installing $binary from $repo $tag"
  download_verified \
    "https://github.com/${repo}/releases/download/${tag}/${asset}" \
    "$dest" "$checksum_url" "$asset"
  install_managed_binary "$dest" "$binary" "${tag#v}" "github:$repo"
  rm -rf "$tmpdir"
  log_success "$binary $tag installed"
  ((_INSTALLED++)) || true
}

package_version() {
  local section="$1" key="$2" default="${3:-}" manifest
  manifest="${DOTFILES_PACKAGES_FILE:-$DOTFILES_SOURCE_DIR/packages.yaml}"
  [[ -f "$manifest" ]] || {
    printf '%s\n' "$default"
    return 0
  }

  awk -v section="$section" -v key="$key" -v fallback="$default" '
    $0 ~ "^[[:space:]]*" section ":[[:space:]]*$" { inside = 1; next }
    inside && $0 ~ "^[^[:space:]#].*:[[:space:]]*$" { inside = 0 }
    inside && $1 == key ":" {
      value = $2
      sub(/[[:space:]#].*$/, "", value)
      gsub(/[\047\"]/, "", value)
      print value
      found = 1
      exit
    }
    END { if (!found) print fallback }
  ' "$manifest"
}

package_metadata() {
  local section="$1" key="$2" field="$3" default="${4:-}" metadata
  metadata="${DOTFILES_PACKAGES_META_FILE:-$DOTFILES_SOURCE_DIR/packages.meta.yaml}"
  [[ -f "$metadata" ]] || {
    printf '%s\n' "$default"
    return 0
  }

  awk -v section="$section" -v key="$key" -v field="$field" -v fallback="$default" '
    $0 == section ":" { in_section = 1; next }
    in_section && $0 ~ /^[^[:space:]#].*:[[:space:]]*$/ { in_section = 0 }
    in_section && $0 == "  " key ":" { in_tool = 1; next }
    in_tool && $0 ~ /^  [^[:space:]#].*:[[:space:]]*$/ { in_tool = 0 }
    in_tool && $0 ~ "^    " field ":[[:space:]]*" {
      value = $0
      sub("^    " field ":[[:space:]]*", "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[\047\"]|[\047\"]$/, "", value)
      print value
      found = 1
      exit
    }
    END { if (!found) print fallback }
  ' "$metadata"
}

managed_state_root() {
  printf '%s\n' "${DOTFILES_STATE_DIR:-$HOME/.local/state/dotfiles}"
}

record_install() {
  local tool="$1" version="$2" owner="$3" target="$4"
  local ledger root
  root="$(managed_state_root)"
  ledger="$root/installed.tsv"
  umask 077
  mkdir -p "$root"
  touch "$ledger"
  awk -F '\t' -v tool="$tool" -v target="$target" \
    '!( $1 == tool && $4 == target )' "$ledger" >"$ledger.tmp"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tool" "$version" "$owner" "$target" "${DOTFILES_SECTION:-unknown}" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$ledger.tmp"
  mv "$ledger.tmp" "$ledger"
  chmod 600 "$ledger"
}

managed_link() {
  local target="$1" link="$2" tool="$3" version="$4"
  mkdir -p "$(dirname "$link")"
  ln -sfn "$target" "$link"
  record_install "$tool" "$version" symlink "$link"
}

npm_global_prefix() {
  printf '%s\n' "${DOTFILES_NPM_PREFIX:-$HOME/.local/share/npm}"
}

activate_node_paths() {
  local prefix
  prefix="$(npm_global_prefix)"
  export PATH="$HOME/.local/bin:$prefix/bin:$PATH"
}

npm_install_global() {
  local package="$1" version="$2" binary="$3"
  local prefix
  prefix="$(npm_global_prefix)"
  activate_node_paths
  if command_exists "$binary" && version_ge "$($binary --version 2>/dev/null || true)" "$version"; then
    log_skip "$binary $version already installed or newer"
    return 0
  fi
  mkdir -p "$prefix"
  npm install --global --prefix "$prefix" --no-audit --no-fund "${package}@${version}"
  if ! command_exists "$binary"; then
    log_error "$binary was not found after installing ${package}@${version}"
    return 1
  fi
  record_install "$binary" "$version" "npm:$package" "$prefix/lib/node_modules/$package"
  log_success "$binary $version installed"
  ((_INSTALLED++)) || true
}

section_manifest_hash() {
  local section="$1"
  awk -v section="$section" '
    $0 ~ "^" section ":[[:space:]]*$" { inside = 1 }
    inside && NR > 1 && $0 ~ "^[^[:space:]#].*:[[:space:]]*$" && $0 !~ "^" section ":" { exit }
    inside { print }
  ' "$DOTFILES_SOURCE_DIR/packages.yaml" | sha256sum | awk '{print $1}'
}

print_summary() {
  local name="${1:-$(basename "$0")}" total
  total=$((_INSTALLED + _SKIPPED + _WARNINGS + _FAILED))
  printf '\n%b-- Summary: %s --%b\n' "$BOLD" "$name" "$NC"
  printf '  %bInstalled:%b %s  %bSkipped:%b %s  %bWarnings:%b %s  %bFailed:%b %s  Total: %s\n' \
    "$GREEN" "$NC" "$_INSTALLED" "$DIM" "$NC" "$_SKIPPED" \
    "$YELLOW" "$NC" "$_WARNINGS" "$RED" "$NC" "$_FAILED" "$total"
  emit_event summary "installed=$_INSTALLED skipped=$_SKIPPED warnings=$_WARNINGS failed=$_FAILED"
  [[ $_FAILED -eq 0 ]]
}
