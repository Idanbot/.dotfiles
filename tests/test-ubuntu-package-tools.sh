#!/usr/bin/env bash
# Exercise distro-managed tools required by the terminal and cloud profiles.

set -euo pipefail

for command in gojq pigz zstd kcat pgloader; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Required Ubuntu package tool is unavailable: %s\n' "$command" >&2
    exit 1
  }
done

printf '{"ready":true}\n' | gojq -e '.ready == true' >/dev/null
[[ "$(printf 'pigz-smoke\n' | pigz | pigz -d)" == pigz-smoke ]]
[[ "$(printf 'zstd-smoke\n' | zstd -q | zstd -dq)" == zstd-smoke ]]
kcat -V >/dev/null
pgloader --version >/dev/null

printf 'Ubuntu package tool smoke passed\n'
