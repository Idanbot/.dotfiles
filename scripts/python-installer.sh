#!/usr/bin/env bash
# Install exact Python with a compatible uv without replacing an external uv.
set -euo pipefail
DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"
mode="${1:---check}"
[[ "$mode" == --check || "$mode" == --install ]] || exit 2
python_version="$(package_version languages python)"
uv_version="$(package_version languages uv)"
if command_exists python3 && version_ge "$(python3 --version 2>/dev/null || true)" "$python_version"; then
  log_info "Active Python already satisfies $python_version; keeping it"
  exit 0
fi
if command_exists uv && timeout 15 uv python find "$python_version" >/dev/null 2>&1; then
  log_info "Python $python_version already available through uv"
  exit 0
fi
catalog_has_python() {
  timeout 30 "$1" python list --all-versions --only-downloads "$python_version" 2>/dev/null |
    grep -F "cpython-${python_version}-" >/dev/null
}
uv_command="$(command -v uv || true)"
temporary=""
trap '[[ -z "$temporary" ]] || rm -rf -- "$temporary"' EXIT
if [[ -z "$uv_command" ]] || ! catalog_has_python "$uv_command"; then
  log_warn "Existing uv cannot resolve Python $python_version; using verified private uv $uv_version"
  temporary="$(mktemp -d)"
  case "$(get_arch)" in
    amd64) target=x86_64-unknown-linux-gnu ;;
    arm64) target=aarch64-unknown-linux-gnu ;;
    *) exit 1 ;;
  esac
  asset="uv-${target}.tar.gz"
  base="https://github.com/astral-sh/uv/releases/download/${uv_version}"
  download_verified "$base/$asset" "$temporary/uv.tar.gz" "$base/$asset.sha256" "$asset"
  tar -xzf "$temporary/uv.tar.gz" -C "$temporary"
  uv_command="$temporary/uv-$target/uv"
  version_ge "$("$uv_command" --version)" "$uv_version" || exit 1
  if ! catalog_has_python "$uv_command"; then
    log_error "Pinned uv $uv_version has no Python $python_version download for this host; update the grouped pins and retry"
    exit 1
  fi
fi
if [[ "$mode" == --install ]]; then
  "$uv_command" python install "$python_version"
else
  log_success "Python $python_version download is available; existing uv and system Python remain untouched"
fi
