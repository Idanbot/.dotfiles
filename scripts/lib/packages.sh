#!/usr/bin/env bash
# Internal packages helpers; source scripts/lib.sh as the public entry point.

_SUDO_KEEPALIVE_PID=""

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
  apt_env apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any -qq update
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

  /usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/dotfiles/metadata.py" \
    version "$manifest" "$section" "$key" "$default"
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

  /usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/dotfiles/metadata.py" \
    field "$metadata" "$section" "$key" "$field" "$default"
}

section_manifest_hash() {
  /usr/bin/python3 "$DOTFILES_SOURCE_DIR/scripts/dotfiles/metadata.py" \
    section-hash "${DOTFILES_PACKAGES_FILE:-$DOTFILES_SOURCE_DIR/packages.yaml}" "$1"
}
