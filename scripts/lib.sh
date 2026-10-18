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
  value=${value//$'\b'/\\b}
  value=${value//$'\f'/\\f}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  value=${value//$'\v'/\\u000b}
  value=${value//$'\a'/\\u0007}
  printf '%s' "$value"
}

emit_event() {
  local level="$1"
  shift
  [[ -n "${DOTFILES_EVENT_LOG:-}" ]] || return 0
  umask 077
  mkdir -p "$(dirname "$DOTFILES_EVENT_LOG")"
  printf '{"time":"%s","run_id":"%s","section":"%s","level":"%s","message":"%s"}\n' \
    "$(json_escape "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")" \
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
dpkg_package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Fq 'install ok installed'
}

docker_apt_packages() {
  local has_ce=false
  if dpkg_package_installed containerd.io ||
    dpkg_package_installed docker-ce ||
    dpkg_package_installed docker-ce-cli; then
    has_ce=true
  fi

  if is_installed docker; then
    if docker compose version >/dev/null 2>&1; then
      return 0
    fi
    if [[ "$has_ce" == true ]]; then
      printf '%s\n' docker-compose-plugin
    else
      printf '%s\n' docker-compose-v2
    fi
  elif [[ "$has_ce" == true ]]; then
    printf '%s\n' \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  else
    printf '%s\n' docker.io docker-compose-v2
  fi
}

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
  refresh_hashicorp_apt_keys || return 1
  apt_env apt-get -o Acquire::Retries=3 -qq update
}

refresh_hashicorp_apt_keys() {
  local keyrings keyring fingerprints
  local expected=D55C0D1AC78A8D8126CB631CFC9CA96ACA026560
  keyrings="$(/usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/hashicorp-keyrings.py" \
    "${DOTFILES_APT_SOURCES_DIR:-/etc/apt}")" || return 1
  [[ -n "$keyrings" ]] || return 0
  command_exists gpg || {
    log_error 'HashiCorp APT key repair requires gnupg; install it from Ubuntu first'
    return 1
  }
  while IFS= read -r keyring; do
    [[ ! -L "$keyring" && "$(realpath -m -- "$(dirname "$keyring")")" == "$(dirname "$keyring")" ]] || {
      log_error "Preserving redirected HashiCorp keyring: $keyring"
      return 1
    }
    fingerprints="$(gpg --show-keys --with-colons "$keyring" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }' || true)"
    if grep -Fxq "$expected" <<<"$fingerprints"; then
      continue
    fi
    log_info "Refreshing HashiCorp's scoped APT signing key: $keyring"
    sudo mkdir -p "$(dirname "$keyring")" || return 1
    install_apt_key https://apt.releases.hashicorp.com/gpg "$keyring" "$expected" || return 1
  done <<<"$keyrings"
}

apt_install() {
  local packages=("$@") to_install=() pkg
  for pkg in "${packages[@]}"; do
    if dpkg_package_installed "$pkg"; then
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

reconcile_apt_source() {
  local destination="$1" content="$2" obsolete
  shift 2
  sudo mkdir -p "$(dirname "$destination")"
  printf '%s\n' "$content" | sudo tee "$destination" >/dev/null
  for obsolete in "$@"; do
    [[ "$obsolete" == "$destination" ]] || sudo rm -f "$obsolete"
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

retry_command() {
  local label="$1" attempts="$2" delay="$3"
  shift 3
  local attempt status

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$@"; then
      return 0
    else
      status=$?
    fi

    if ((attempt == attempts)); then
      log_error "$label failed after $attempts attempts"
      return "$status"
    fi

    log_warn "$label failed (attempt $attempt/$attempts); retrying in ${delay}s"
    sleep "$delay"
  done
}

download_once() {
  local url="$1" dest="$2" partial status
  partial="${dest}.part.$$"
  rm -f "$partial"
  if command_exists curl; then
    if curl --proto '=https' --tlsv1.2 \
      --connect-timeout 20 --max-time 180 \
      --retry 2 --retry-all-errors --retry-delay 1 --retry-max-time 60 \
      -fsSL -o "$partial" "$url"; then
      mv -f "$partial" "$dest"
      return 0
    else
      status=$?
    fi
  elif command_exists wget; then
    if wget --https-only --timeout=180 --tries=2 -qO "$partial" "$url"; then
      mv -f "$partial" "$dest"
      return 0
    else
      status=$?
    fi
  else
    log_error "curl or wget is required to download $url"
    return 1
  fi
  rm -f "$partial"
  return "$status"
}

download() {
  local url="$1" dest="$2"
  local attempts="${DOTFILES_DOWNLOAD_ATTEMPTS:-3}"
  local delay="${DOTFILES_DOWNLOAD_RETRY_DELAY:-2}"
  mkdir -p "$(dirname "$dest")"
  retry_command "Download $url" "$attempts" "$delay" download_once "$url" "$dest"
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
  local file="$1" expected="$2" label="${3:-$(basename "$1")}" actual
  actual="$(sha256_file "$file")"
  if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
    log_error "Invalid SHA256 declaration for $label"
    return 1
  fi
  if [[ "${actual,,}" != "${expected,,}" ]]; then
    log_error "Checksum mismatch for $label: expected $expected, got $actual"
    return 1
  fi
  log_success "Verified SHA256 for $label"
}

sha256_matches() {
  local file="$1" expected="$2" actual
  [[ -f "$file" ]] || return 1
  actual="$(sha256_file "$file")"
  [[ "${actual,,}" == "${expected,,}" ]]
}

download_cache_enabled() {
  local enabled="${DOTFILES_DOWNLOAD_CACHE:-1}"
  case "${enabled,,}" in
    0 | false | no | off) return 1 ;;
    *) return 0 ;;
  esac
}

download_cache_root() {
  printf '%s\n' \
    "${DOTFILES_DOWNLOAD_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/downloads}"
}

prepare_download_cache() {
  local root="$1"
  mkdir -p "$root/sha256" "$root/locks" "$root/tmp" || return 1
  chmod 700 "$root" "$root/sha256" "$root/locks" "$root/tmp" || return 1
}

materialize_cached_download() {
  local cache_file="$1" dest="$2" expected="$3" candidate
  candidate="$(mktemp "${dest}.verified.XXXXXX")"
  if ! cp -- "$cache_file" "$candidate"; then
    rm -f "$candidate"
    return 1
  fi
  chmod 600 "$candidate"
  if ! sha256_matches "$candidate" "$expected"; then
    rm -f "$candidate"
    return 1
  fi
  mv -f "$candidate" "$dest"
}

download_verified_direct() {
  local url="$1" dest="$2" expected="$3" label="$4" candidate
  candidate="$(mktemp "${dest}.verified.XXXXXX")"
  if ! download "$url" "$candidate"; then
    rm -f "$candidate"
    return 1
  fi
  if ! verify_sha256 "$candidate" "$expected" "$label"; then
    rm -f "$candidate"
    return 1
  fi
  mv -f "$candidate" "$dest"
}

download_verified() {
  local url="$1" dest="$2" checksum_spec="$3" checksum_name
  local expected checksum_file cache_root cache_file cache_candidate lock_file cache_lock_fd status
  checksum_name="${4:-$(basename "$dest")}"
  mkdir -p "$(dirname "$dest")"

  case "$checksum_spec" in
    sha256:*)
      expected="${checksum_spec#sha256:}"
      ;;
    https://*)
      checksum_file="$(mktemp)"
      if ! download "$checksum_spec" "$checksum_file"; then
        rm -f "$checksum_file"
        return 1
      fi
      expected="$(checksum_for_asset "$checksum_file" "$checksum_name")"
      rm -f "$checksum_file"
      ;;
    *)
      log_error "Unverified download blocked: $url"
      return 1
      ;;
  esac

  if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
    log_error "Invalid or missing SHA256 declaration for $checksum_name"
    return 1
  fi
  expected="${expected,,}"

  if ! download_cache_enabled || ! command_exists flock; then
    download_verified_direct "$url" "$dest" "$expected" "$checksum_name"
    return
  fi

  cache_root="$(download_cache_root)"
  if ! prepare_download_cache "$cache_root"; then
    log_warn "Verified download cache is unavailable at $cache_root; downloading directly"
    download_verified_direct "$url" "$dest" "$expected" "$checksum_name"
    return
  fi

  cache_file="$cache_root/sha256/$expected"
  lock_file="$cache_root/locks/$expected.lock"
  if ! { exec {cache_lock_fd}>"$lock_file"; }; then
    log_warn "Cannot open the verified download cache lock; downloading directly"
    download_verified_direct "$url" "$dest" "$expected" "$checksum_name"
    return
  fi
  chmod 600 "$lock_file"
  if ! flock -w "${DOTFILES_DOWNLOAD_CACHE_LOCK_TIMEOUT:-300}" "$cache_lock_fd"; then
    exec {cache_lock_fd}>&-
    log_error "Timed out waiting for verified download cache entry $expected"
    return 1
  fi

  if [[ -e "$cache_file" ]] && ! sha256_matches "$cache_file" "$expected"; then
    log_warn "Discarding corrupt verified download cache entry $expected"
    rm -f "$cache_file"
  fi

  if [[ -f "$cache_file" ]]; then
    touch "$cache_file"
    if materialize_cached_download "$cache_file" "$dest" "$expected"; then
      log_success "Verified SHA256 for $checksum_name (cache hit)"
      status=0
    else
      log_error "Failed to materialize cached download for $checksum_name"
      status=1
    fi
    flock -u "$cache_lock_fd"
    exec {cache_lock_fd}>&-
    return "$status"
  fi

  cache_candidate="$(mktemp "$cache_root/tmp/${expected}.XXXXXX")"
  if ! download "$url" "$cache_candidate"; then
    rm -f "$cache_candidate"
    flock -u "$cache_lock_fd"
    exec {cache_lock_fd}>&-
    return 1
  fi
  if ! verify_sha256 "$cache_candidate" "$expected" "$checksum_name"; then
    rm -f "$cache_candidate"
    flock -u "$cache_lock_fd"
    exec {cache_lock_fd}>&-
    return 1
  fi
  chmod 600 "$cache_candidate"
  mv -f "$cache_candidate" "$cache_file"
  log_info "Cached verified download for $checksum_name"
  if materialize_cached_download "$cache_file" "$dest" "$expected"; then
    status=0
  else
    log_error "Failed to materialize cached download for $checksum_name"
    status=1
  fi
  flock -u "$cache_lock_fd"
  exec {cache_lock_fd}>&-
  return "$status"
}

github_latest_release() {
  local repo="$1" auth_header=() tag
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  [[ -n "$token" ]] && auth_header=(-H "Authorization: Bearer $token")
  tag=$(curl --proto '=https' --tlsv1.2 --retry 3 -fsSL \
    "${auth_header[@]}" \
    "https://api.github.com/repos/${repo}/releases/latest" |
    sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -1)
  [[ -n "$tag" ]] || {
    log_error "Failed to resolve latest release for $repo (API rate limit?)"
    return 1
  }
  printf '%s\n' "$tag"
}

download_aws_signed() (
  local url="$1" destination="$2" temporary fingerprint digest
  temporary="$(mktemp -d)"
  trap 'rm -rf -- "$temporary"' EXIT
  chmod 700 "$temporary"
  gpg --batch --homedir "$temporary" --import "$DOTFILES_SOURCE_DIR/scripts/keys/aws-cli.asc" >/dev/null 2>&1
  fingerprint="$(gpg --batch --homedir "$temporary" --with-colons --fingerprint | awk -F: '$1 == "fpr" {print $10; exit}')"
  [[ "$fingerprint" == FB5DB77FD5C118B80511ADA8A6310ACC4672475C ]] || {
    log_error "AWS CLI public signing key fingerprint mismatch"
    return 1
  }
  download "$url" "$temporary/aws.zip"
  download "$url.sig" "$temporary/aws.zip.sig"
  gpg --batch --homedir "$temporary" --verify "$temporary/aws.zip.sig" "$temporary/aws.zip" || {
    log_error "AWS CLI signature verification failed; nothing installed"
    return 1
  }
  digest="$(sha256_file "$temporary/aws.zip")"
  log_success "Verified AWS CLI signature; SHA256 $digest"
  # Persist the verified payload identity alongside the immutable version plan.
  if [[ -n "${DOTFILES_VERSION_PLAN:-}" ]]; then
    printf '%s\n' "$digest" >"${DOTFILES_VERSION_PLAN%.json}-aws.sha256"
    chmod 600 "${DOTFILES_VERSION_PLAN%.json}-aws.sha256"
  fi
  install -m 600 "$temporary/aws.zip" "$destination"
)

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

binary_replacement_requested() {
  [[ ",${DOTFILES_REPLACE_BINARIES:-}," == *",$1,"* ]]
}

preserve_existing_release_binary() {
  local binary="$1" current="$2" target="${DOTFILES_BIN_DIR:-$HOME/.local/bin}/$1"
  # Policy-managed runs must not shadow an executable owned by another installer.
  if [[ -n "${DOTFILES_VERSION_PLAN:-}" ]] && command_exists "$binary"; then
    target="$(command -v "$binary")"
    if [[ "$binary" == aws ]] && target_is_owned /usr/local/aws-cli; then
      return 1
    fi
    if [[ ! -f "$target" || ! -x "$target" ]]; then
      log_warn "Preserving unowned $binary at $target; update skipped"
      return 0
    fi
  fi
  [[ -e "$target" || -L "$target" ]] || return 1
  target_is_owned "$target" && return 1
  binary_replacement_requested "$binary" && return 1
  [[ -f "$target" && -x "$target" ]] || return 1
  [[ -n "${DOTFILES_VERSION_PLAN:-}" || -n "$(extract_version "$current")" ]] || return 1
  log_warn "Preserving existing $binary ($current) at $target; upgrade skipped because it is unowned or modified"
  log_info "To back it up and replace only this binary, rerun with DOTFILES_REPLACE_BINARIES=$binary"
  return 0
}

runtime_is_current() {
  local binary="$1" target="$2" current="$3"
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

version_plan_value() {
  [[ -n "${DOTFILES_VERSION_PLAN:-}" ]] || return 0
  /usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/install-policy.py" get \
    --plan "$DOTFILES_VERSION_PLAN" --tool "$1" --field "$2"
}

install_policy_apt() {
  local binary="$1" package="$2" id="$3" current="$4" target versions candidate
  target="$(version_plan_value "$id" target)"
  if [[ -z "$target" ]]; then
    sudo apt-get install -y "$package"
    return
  fi
  if command_exists "$binary"; then
    if version_ge "$current" "$target"; then
      log_skip "$binary $(extract_version "$current") is at or above run target $target"
      return
    fi
    if ! dpkg-query -S "$(readlink -f "$(command -v "$binary")")" 2>/dev/null |
      grep -Fq "$package:"; then
      log_warn "Preserving unowned $binary at $(command -v "$binary"); update skipped"
      return
    fi
  fi
  versions="$(apt-cache madison "$package")"
  candidate="$(awk -F '|' -v target="$target" '
    { gsub(/^[ \t]+|[ \t]+$/, "", $2)
      if ($2 == target || index($2, target "-") == 1) {print $2; exit} }
  ' <<<"$versions")"
  [[ -n "$candidate" ]] || {
    log_error "$package $target is not yet available from its signed APT repository; retry after publication"
    return 1
  }
  sudo apt-get install -y "$package=$candidate"
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
  ((_INSTALLED++)) || true
}

package_version() {
  local section="$1" key="$2" default="${3:-}" manifest
  local resolved
  if [[ -n "${DOTFILES_VERSION_PLAN:-}" ]]; then
    resolved="$(version_plan_value "$section.$key" target)"
    if [[ -n "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return
    fi
  fi
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
      gsub(/[\047"]/, "", value)
      print value
      found = 1
      exit
    }
    END { if (!found) print fallback }
  ' "$manifest"
}

package_metadata() {
  local section="$1" key="$2" field="$3" default="${4:-}" metadata
  local resolved
  if [[ -n "${DOTFILES_VERSION_PLAN:-}" && "$field" == sha256_* ]]; then
    resolved="$(version_plan_value "$section.$key" integrity)"
    if [[ "$resolved" == sha256:* ]]; then
      printf '%s\n' "${resolved#sha256:}"
      return
    fi
  fi
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
      gsub(/^[\047"]|[\047"]$/, "", value)
      print value
      found = 1
      exit
    }
    END { if (!found) print fallback }
  ' "$metadata"
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

managed_state_root() {
  printf '%s\n' "${DOTFILES_STATE_DIR:-$HOME/.local/state/dotfiles}"
}

ensure_private_directory() {
  local directory="$1"
  umask 077
  mkdir -p "$directory"
  chmod 700 "$directory"
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

npm_global_prefix() {
  printf '%s\n' "${DOTFILES_NPM_PREFIX:-$HOME/.local/share/npm}"
}

activate_node_paths() {
  local prefix
  prefix="$(npm_global_prefix)"
  export PATH="$HOME/.local/bin:$prefix/bin:$PATH"
}

npm_install_global() {
  local package="$1" version="$2" binary="$3" allow_scripts="${4:-}"
  local prefix package_manifest installed_version=""
  local -a npm_args=(
    install --global --prefix
    "$(npm_global_prefix)"
    --no-audit
    --no-fund
  )
  prefix="$(npm_global_prefix)"
  package_manifest="$prefix/lib/node_modules/$package/package.json"
  local active_version
  active_version="$($binary --version 2>/dev/null || true)"
  if [[ -n "${DOTFILES_VERSION_PLAN:-}" ]] && runtime_is_current "$binary" "$version" "$active_version"; then
    return 0
  fi
  activate_node_paths
  if [[ -f "$package_manifest" ]]; then
    if command_exists gojq; then
      installed_version="$(gojq -r '.version // ""' "$package_manifest" 2>/dev/null || true)"
    elif command_exists node; then
      installed_version="$(node -e \
        'process.stdout.write(require(process.argv[1]).version || "")' \
        "$package_manifest" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$installed_version" ]] ||
    installed_version="$($binary --version 2>/dev/null || true)"
  if command_exists "$binary" && version_ge "$installed_version" "$version"; then
    [[ -x "$prefix/bin/$binary" ]] &&
      managed_link "$prefix/bin/$binary" "$HOME/.local/bin/$binary" "$binary" "$version"
    log_skip "$binary $version already installed or newer"
    return 0
  fi
  mkdir -p "$prefix"
  [[ -n "$allow_scripts" ]] && npm_args+=("--allow-scripts=$allow_scripts")
  npm "${npm_args[@]}" "${package}@${version}"
  if [[ ! -x "$prefix/bin/$binary" ]]; then
    log_error "$binary was not found after installing ${package}@${version}"
    return 1
  fi
  managed_link "$prefix/bin/$binary" "$HOME/.local/bin/$binary" "$binary" "$version"
  record_install "$binary" "$version" "npm:$package" "$prefix/lib/node_modules/$package"
  log_success "$binary $version installed"
  ((_INSTALLED++)) || true
}

omp_install_package() {
  local package="$1" version="$2" tool="$3"
  local root manifest installed_version="" spec
  root="${DOTFILES_OMP_PLUGIN_ROOT:-$HOME/.omp/plugins}"
  manifest="$root/node_modules/$package/package.json"
  spec="${package}@${version}"

  if [[ -f "$manifest" ]]; then
    installed_version="$(jq -r '.version // empty' "$manifest" 2>/dev/null || true)"
  fi
  if version_equals "$installed_version" "$version"; then
    log_skip "$tool $version already installed in OMP"
    return 0
  fi

  log_info "Installing $tool $version for OMP"
  omp plugin install "$spec"
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
  local state="$HOME/.omp/agent/optimizer.json" tmp
  if [[ -e "$state" ]]; then
    jq empty "$state" >/dev/null 2>&1 ||
      log_warn "Existing Pix Optimizer state is invalid and was preserved: $state"
    return 0
  fi
  ensure_private_directory "$(dirname "$state")"
  tmp="$(mktemp "${state}.XXXXXX")"
  jq -n '{caveman: "off", rtk: "off", ponytail: "off"}' >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$state"
  log_success "Pix Optimizer initialized with all modes off"
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
