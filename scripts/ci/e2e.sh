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
trap 'docker compose -p "$project" -f .github/e2e/compose.yaml --profile "$profile" down --volumes' EXIT
docker compose -p "$project" -f .github/e2e/compose.yaml --profile "$profile" \
  up --build --abort-on-container-exit --exit-code-from "$service" "$service"
