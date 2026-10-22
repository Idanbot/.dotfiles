#!/usr/bin/env bash
set -euo pipefail
service="${1:?usage: e2e.sh SERVICE}"
case "$service" in
  base-native | base-wsl-simulated) profile=base ;;
  recovery | failure-resume) profile=recovery ;;
  developer | agent | cloud | full | full-native) profile="$service" ;;
  *)
    printf 'Unsupported E2E service: %s\n' "$service" >&2
    exit 2
    ;;
esac
mkdir -p artifacts
[[ "$(stat -c '%a' artifacts)" == 777 ]] || chmod 0777 artifacts
project="dotfiles-ci-${service}-$(date +%s)-$$"
cleanup() {
  local status=$?
  trap - EXIT
  if ! docker compose -p "$project" -f .github/e2e/compose.yaml --profile "$profile" \
    down --volumes >"artifacts/$service-cleanup.log" 2>&1; then
    printf 'E2E cleanup failed; see artifacts/%s-cleanup.log\n' "$service" >&2
    ((status != 0)) || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
docker compose -p "$project" -f .github/e2e/compose.yaml --profile "$profile" \
  up --build --abort-on-container-exit --exit-code-from "$service" "$service" \
  2>&1 | tee "artifacts/$service-compose.log"
