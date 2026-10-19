#!/usr/bin/env bash
# CI-only legacy upgrade fixture: stale external uv, private fallback and unavailable Python.
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
export HOME="$temporary/home" DOTFILES_SOURCE_DIR="$ROOT"
export DOTFILES_PACKAGES_FILE="$temporary/packages.yaml"
export DOTFILES_DOWNLOAD_CACHE_DIR="$temporary/cache"
export FIXTURE_ROOT="$temporary"
mkdir -p "$HOME/.local/bin" "$temporary/bin" "$temporary/archive"
printf 'languages:\n  uv: "0.13.0"\n  python: "99.0.0"\n' >"$DOTFILES_PACKAGES_FILE"
cat >"$HOME/.local/bin/uv" <<'EOF'
#!/bin/sh
case "$*" in
  --version) echo 'uv 0.1.0' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$HOME/.local/bin/uv"
before="$(sha256sum "$HOME/.local/bin/uv")"
case "$(uname -m)" in
  x86_64) target=x86_64-unknown-linux-gnu ;;
  aarch64) target=aarch64-unknown-linux-gnu ;;
  *) exit 1 ;;
esac
mkdir -p "$temporary/archive/uv-$target"
cat >"$temporary/archive/uv-$target/uv" <<'EOF'
#!/bin/sh
case "$*" in
  --version) echo 'uv 0.13.0' ;;
  'python list '*)
    [ "${FIXTURE_UNAVAILABLE:-0}" = 0 ] || exit 0
    echo 'cpython-99.0.0-linux-x86_64-gnu <download available>'
    ;;
  'python install 99.0.0') touch "$FIXTURE_ROOT/installed" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$temporary/archive/uv-$target/uv"
tar -czf "$temporary/uv.tar.gz" -C "$temporary/archive" "uv-$target"
sha256sum "$temporary/uv.tar.gz" | awk -v asset="uv-$target.tar.gz" '{print $1 "  " asset}' >"$temporary/checksum"
cat >"$temporary/bin/curl" <<'EOF'
#!/bin/bash
while (($#)); do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >>"$FIXTURE_ROOT/requests"
case "$url" in
  *.sha256) cp "$FIXTURE_ROOT/checksum" "$dest" ;;
  *.tar.gz) cp "$FIXTURE_ROOT/uv.tar.gz" "$dest" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$temporary/bin/curl"
export PATH="$temporary/bin:$HOME/.local/bin:/usr/bin:/bin"
bash "$ROOT/scripts/python-installer.sh" --check
[[ ! -e "$temporary/installed" ]]
[[ "$(wc -l <"$temporary/requests")" == 2 ]]
bash "$ROOT/scripts/python-installer.sh" --install
[[ -e "$temporary/installed" ]]
[[ "$(wc -l <"$temporary/requests")" == 2 ]]
[[ "$before" == "$(sha256sum "$HOME/.local/bin/uv")" ]]
rm "$temporary/installed"
if FIXTURE_UNAVAILABLE=1 bash "$ROOT/scripts/python-installer.sh" --install; then
  printf 'Unavailable pinned Python was accepted\n' >&2
  exit 1
fi
[[ ! -e "$temporary/installed" ]]
[[ "$before" == "$(sha256sum "$HOME/.local/bin/uv")" ]]
printf 'Private uv compatibility, cache reuse, exact Python, and preservation tests passed\n'
