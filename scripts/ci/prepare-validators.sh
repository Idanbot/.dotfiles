#!/usr/bin/env bash
# Template/runtime fixtures need the pinned prompt renderer, not a live install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/environment.sh
source "$ROOT/scripts/environment.sh"
spec="$(
  PYTHONPATH="$ROOT/scripts" /usr/bin/python3 - "$ROOT" "$(get_arch)" <<'PY'
import json
from pathlib import Path
import sys
from dotfiles.metadata import load_repository, release_spec

versions, metadata = load_repository(Path(sys.argv[1]))
print(json.dumps(release_spec(metadata["core"]["starship"], versions["core"]["starship"], sys.argv[2])))
PY
)"
asset="$(jq -r .asset <<<"$spec")"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
url="https://github.com/$(jq -r .repo <<<"$spec")/releases/download/$(jq -r .tag <<<"$spec")/$asset"
curl -fsSLo "$temporary/$asset" "$url"
checksum="$(curl -fsSL "$url.sha256" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "$temporary/$asset" | sha256sum -c -
mkdir -p "$HOME/.local/bin"
tar -xzf "$temporary/$asset" -C "$HOME/.local/bin" starship
