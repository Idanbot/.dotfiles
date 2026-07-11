#!/usr/bin/env bash
# Build a disposable Ubuntu E2E machine, validate it, and keep it open for inspection.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/.github/e2e/compose.yaml"

PROFILE="full"
PLATFORM="native"
PASSES="1"
BUILD=true
PRINT_COMMAND=false

usage() {
  cat <<'EOF'
Usage: scripts/e2e-shell.sh [options]

Run the real installer and its acceptance checks in a disposable Ubuntu 24.04
container, then open a login shell for manual validation.

Options:
  --profile NAME       minimal|base|developer|agent|cloud|full (default: full)
  --platform NAME      native|wsl (default: native; wsl is simulated)
  --passes COUNT       Installation passes before opening the shell (default: 1)
  --no-build           Reuse the existing Docker image without rebuilding it
  --print-command      Print the resolved Docker command without running it
  -h, --help           Show this help

Inside the container, DOTFILES_E2E_STATUS is 0 when automated validation passed.
Exit the shell to remove the container. Logs and diagnostics remain in artifacts/.
EOF
}

die() {
  printf 'e2e-shell: %s\n' "$*" >&2
  exit 2
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" && "$value" != --* ]] || die "$option requires a value"
}

while (($# > 0)); do
  case "$1" in
    --profile)
      require_value "$1" "${2:-}"
      PROFILE="$2"
      shift 2
      ;;
    --profile=*)
      PROFILE="${1#*=}"
      shift
      ;;
    --platform)
      require_value "$1" "${2:-}"
      PLATFORM="$2"
      shift 2
      ;;
    --platform=*)
      PLATFORM="${1#*=}"
      shift
      ;;
    --passes)
      require_value "$1" "${2:-}"
      PASSES="$2"
      shift 2
      ;;
    --passes=*)
      PASSES="${1#*=}"
      shift
      ;;
    --no-build)
      BUILD=false
      shift
      ;;
    --print-command)
      PRINT_COMMAND=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$PROFILE" in
  minimal | base | developer | agent | cloud | full) ;;
  *) die "unsupported profile '$PROFILE'" ;;
esac

case "$PLATFORM" in
  native) WSL=false ;;
  wsl) WSL=true ;;
  *) die "unsupported platform '$PLATFORM' (expected native or wsl)" ;;
esac

[[ "$PASSES" =~ ^[1-9][0-9]*$ ]] || die "--passes must be a positive integer"

CONTAINER_COMMAND=$(
  cat <<'EOF'
e2e_status=0
/dotfiles/tests/e2e/test-install.sh || e2e_status=$?
export DOTFILES_E2E_STATUS="$e2e_status"
export DOTFILES_E2E_PROFILE="$E2E_PROFILE"
export DOTFILES_E2E_PLATFORM="$E2E_PLATFORM"

printf '\n============================================================\n'
if [[ "$e2e_status" -eq 0 ]]; then
  printf ' Automated E2E validation PASSED\n'
else
  printf ' Automated E2E validation FAILED (exit %s)\n' "$e2e_status"
fi
printf ' Profile: %s | Platform: %s | Passes: %s\n' "$E2E_PROFILE" "$E2E_PLATFORM" "$E2E_PASSES"
printf ' Status variable: DOTFILES_E2E_STATUS=%s\n' "$e2e_status"
printf ' Artifacts: /artifacts/%s-%s\n' "$E2E_PROFILE" "$DOTFILES_WSL"
printf ' Try: dot doctor; nvim; tmux; dot workspace /dotfiles\n'
printf ' Exit this shell to remove the disposable container.\n'
printf '============================================================\n\n'

shell_status=0
if command -v zsh >/dev/null 2>&1; then
  zsh -l || shell_status=$?
else
  printf 'Zsh is unavailable; opening Bash because installation failed early.\n' >&2
  bash -l || shell_status=$?
fi

if [[ "$e2e_status" -ne 0 ]]; then
  exit "$e2e_status"
fi
exit "$shell_status"
EOF
)

COMMAND=(
  docker compose
  -f "$COMPOSE_FILE"
  --profile full
  run
)
[[ "$BUILD" == false ]] || COMMAND+=(--build)
COMMAND+=(
  --rm
  -e "DOTFILES_WSL=$WSL"
  -e "E2E_PLATFORM=$PLATFORM"
  -e "E2E_PROFILE=$PROFILE"
  -e "E2E_PASSES=$PASSES"
  full bash -lc "$CONTAINER_COMMAND"
)

if [[ "$PRINT_COMMAND" == true ]]; then
  printf '%q ' "${COMMAND[@]}"
  printf '\n'
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is unavailable"
[[ -t 0 && -t 1 ]] || die "an interactive terminal is required to open the container shell"

mkdir -p "$ROOT_DIR/artifacts"
artifact_other_mode="$(stat -c '%a' "$ROOT_DIR/artifacts")"
artifact_other_mode="${artifact_other_mode: -1}"
case "$artifact_other_mode" in
  3 | 7) ;;
  *)
    chmod 0777 "$ROOT_DIR/artifacts" ||
      die "cannot make $ROOT_DIR/artifacts writable by the E2E container"
    ;;
esac

printf '\n== Dotfiles Manual E2E Shell ==\n'
printf 'Profile:  %s\n' "$PROFILE"
printf 'Platform: %s%s\n' "$PLATFORM" "$([[ "$PLATFORM" == wsl ]] && printf ' (simulated)')"
printf 'Passes:   %s\n' "$PASSES"
printf 'Artifacts: %s/artifacts/%s-%s\n\n' "$ROOT_DIR" "$PROFILE" "$WSL"

exec "${COMMAND[@]}"
