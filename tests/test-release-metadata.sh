#!/usr/bin/env bash
# Repository, tag, asset, and architecture changes must travel together.
set -euo pipefail
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/source" "$temporary/bin"
tar -C "$DOTFILES_DIR" --exclude=.git --exclude=artifacts --exclude=__pycache__ -cf - . |
  tar -C "$temporary/source" -xf -
export DOTFILES_SOURCE_DIR="$temporary/source"
/usr/bin/python3 - "$DOTFILES_SOURCE_DIR/packages.meta.yaml" <<'PY'
from pathlib import Path
import sys
import yaml
path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text())
data['core']['github_cli'].update({
    'repo': 'example/review-fixture',
    'tag_template': 'release-{version}',
    'asset_template': 'tool-{version}-{arch}.tar.gz',
    'arch_amd64': 'x64',
    'arch_arm64': 'a64',
})
path.write_text(yaml.safe_dump(data, sort_keys=False))
PY
cat >"$temporary/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
printf '%s\n' "$url" >>"$MOCK_REQUESTS"
case "$url" in
  https://api.github.com/repos/example/review-fixture/releases/latest)
    printf '{"tag_name":"release-2.999.0"}\n'
    ;;
  https://api.github.com/repos/example/review-fixture/releases/tags/release-2.999.0)
    printf '{"assets":[{"name":"tool-2.999.0-x64.tar.gz","digest":"sha256:%064d"},{"name":"tool-2.999.0-a64.tar.gz","digest":"sha256:%064d"}]}\n' 1 2
    ;;
  *) exit 22 ;;
esac
MOCK
chmod +x "$temporary/bin/curl"
export PATH="$temporary/bin:$PATH" GITHUB_TOKEN=fixture-token
export MOCK_REQUESTS="$temporary/requests"
"$DOTFILES_SOURCE_DIR/scripts/update-packages.sh" --apply core.github_cli \
  --report "$temporary/report.md" >"$temporary/output.log" 2>&1
grep -Fq 'release-2.999.0' "$MOCK_REQUESTS"
grep -Fq 'example/review-fixture' "$MOCK_REQUESTS"
grep -Fq 'github_cli: "2.999.0"' "$DOTFILES_SOURCE_DIR/packages.yaml"
grep -Fq '0000000000000000000000000000000000000000000000000000000000000002' \
  "$DOTFILES_SOURCE_DIR/packages.meta.yaml"
printf 'One metadata edit controls release discovery and both architecture checksums\n'
