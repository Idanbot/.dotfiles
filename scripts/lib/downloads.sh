#!/usr/bin/env bash
# Internal downloads helpers; source scripts/lib.sh as the public entry point.

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

# Cache immutable verification material, not live release indexes or trust decisions.
# The local digest detects cache corruption; vendor signatures/checksums remain authoritative.
download_verification_material() (
  local url="$1" dest="$2" root key file digest temporary cache_fd
  if ! download_cache_enabled || ! command_exists flock ||
    [[ "$url" == *latest* || "$url" == *stable.txt* || "$url" == *components-2.json* || "$url" == */rustup/dist/* ]]; then
    download "$url" "$dest"
    return
  fi
  root="$(download_cache_root)/verification"
  mkdir -p "$root"
  chmod 700 "$root"
  key="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
  file="$root/$key"
  exec {cache_fd}>"$file.lock"
  chmod 600 "$file.lock"
  flock -w "${DOTFILES_DOWNLOAD_CACHE_LOCK_TIMEOUT:-300}" "$cache_fd" || return 1
  if [[ -f "$file" && -f "$file.sha256" ]] && sha256_matches "$file" "$(<"$file.sha256")"; then
    touch "$file" "$file.sha256"
    cp -- "$file" "$dest"
    chmod 600 "$dest"
    return
  fi
  temporary="$(mktemp "$root/.download.XXXXXX")"
  trap 'rm -f -- "$temporary"' EXIT
  download "$url" "$temporary" || return 1
  digest="$(sha256_file "$temporary")"
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$file"
  printf '%s\n' "$digest" >"$file.sha256"
  chmod 600 "$file.sha256"
  cp -- "$file" "$dest"
  chmod 600 "$dest"
)

discard_verification_material() {
  local key root
  root="$(download_cache_root)/verification"
  key="$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
  rm -f -- "$root/$key" "$root/$key.sha256"
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
      if ! download_verification_material "$checksum_spec" "$checksum_file"; then
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
  download_verification_material "$url" "$temporary/aws.zip"
  download_verification_material "$url.sig" "$temporary/aws.zip.sig"
  gpg --batch --homedir "$temporary" --verify "$temporary/aws.zip.sig" "$temporary/aws.zip" || {
    discard_verification_material "$url"
    discard_verification_material "$url.sig"
    log_error "AWS CLI signature verification failed; nothing installed"
    return 1
  }
  digest="$(sha256_file "$temporary/aws.zip")"
  log_success "Verified AWS CLI signature; SHA256 $digest"
  # Persist the verified payload identity alongside the immutable version plan.
  if [[ -n "${DOTFILES_VERSION_PLAN:-}" ]]; then
    if [[ -s "${DOTFILES_VERSION_PLAN%.json}-aws.sha256" ]]; then
      verify_sha256 "$temporary/aws.zip" "$(<"${DOTFILES_VERSION_PLAN%.json}-aws.sha256")" aws-cli-resume || return 1
    else
      printf '%s\n' "$digest" >"${DOTFILES_VERSION_PLAN%.json}-aws.sha256"
      chmod 600 "${DOTFILES_VERSION_PLAN%.json}-aws.sha256"
    fi
  fi
  install -m 600 "$temporary/aws.zip" "$destination"
)
