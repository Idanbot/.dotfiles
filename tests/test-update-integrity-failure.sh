#!/usr/bin/env bash
# Failed integrity lookup must never become an accepted update proposal.
set -euo pipefail
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/source" "$temporary/bin"
tar -C "$DOTFILES_DIR" --exclude=.git --exclude=artifacts --exclude=__pycache__ -cf - . |
  tar -C "$temporary/source" -xf -
cat >"$temporary/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
case "$url" in
  https://nodejs.org/dist/index.json) printf '[{"version":"v26.99.9"}]\n' ;;
  'https://go.dev/dl/?mode=json&include=all') printf '[{"version":"go1.27.99","stable":true,"files":[]}]\n' ;;
  *) exit 22 ;;
esac
MOCK
chmod +x "$temporary/bin/curl"
export PATH="$temporary/bin:$PATH" GITHUB_TOKEN=fixture-token
export DOTFILES_SOURCE_DIR="$temporary/source"
tracked=(packages.yaml packages.meta.yaml packages.lock README.md docs/tool-inventory.md .chezmoiexternal.yaml)
snapshot() {
  (cd "$DOTFILES_SOURCE_DIR" && sha256sum "${tracked[@]}")
}
before="$(snapshot)"
for tool in node go; do
  if "$DOTFILES_SOURCE_DIR/scripts/update-packages.sh" --apply "languages.$tool" \
    --report "$temporary/$tool.md" >"$temporary/$tool.log" 2>&1; then
    printf 'Update accepted failed %s checksum resolution\n' "$tool" >&2
    exit 1
  fi
  grep -Fq unresolved "$temporary/$tool.md"
  grep -Fq 'selected updates contain unresolved checksums' "$temporary/$tool.log"
  [[ "$(snapshot)" == "$before" ]]
done
printf 'Failed checksum resolution preserves every update output\n'
