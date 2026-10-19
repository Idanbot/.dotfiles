#!/usr/bin/env bash
# Keep local and hosted suite execution identical.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
suite="${1:?usage: docker-suite.sh SUITE}"
shift
mkdir -p "$ROOT/artifacts"
[[ "$(stat -c '%a' "$ROOT/artifacts")" == 777 ]] || chmod 0777 "$ROOT/artifacts"
image="${DOTFILES_CI_IMAGE:-dotfiles-ci-tests}"
platform=native
[[ "${DOTFILES_WSL:-false}" != true ]] || platform=wsl-simulated
if [[ "${DOTFILES_CI_SKIP_BUILD:-false}" != true ]]; then
  docker build --target tests -f "$ROOT/.github/e2e/Dockerfile.ubuntu-24.04" -t "$image" "$ROOT"
fi
exec docker run --rm \
  -e DOTFILES_WSL="${DOTFILES_WSL:-false}" \
  -e GITHUB_ACTIONS -e GITHUB_BASE_REF -e GITHUB_TOKEN -e GH_TOKEN \
  -e DOTFILES_E2E_ARTIFACT_DIR=/artifacts/agent-workspace \
  -e CI_RESULTS_DIR="${CI_RESULTS_DIR:-/artifacts/ci/$suite-$platform}" \
  -v "$ROOT:/dotfiles:ro" -v "$ROOT/artifacts:/artifacts" \
  "$image" bash -c '
    set -euo pipefail
    git config --global --add safe.directory /dotfiles
    /dotfiles/scripts/install-chezmoi.sh
    if [[ "$1" == static || "$1" == behavior ]]; then
      /dotfiles/scripts/ci/prepare-validators.sh
    fi
    python3 /dotfiles/scripts/ci/run-tests.py "$@"
  ' bash "$suite" "$@"
