#!/usr/bin/env bash
# Verify Docker packages follow the existing runtime owner without conflicts.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
export DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

MOCK_DOCKER=false
MOCK_COMPOSE=false
MOCK_CE=false

is_installed() {
  [[ "$1" == docker && "$MOCK_DOCKER" == true ]]
}

docker() {
  [[ "$*" == "compose version" && "$MOCK_COMPOSE" == true ]]
}

dpkg_package_installed() {
  [[ "$1" == containerd.io && "$MOCK_CE" == true ]]
}

assert_packages() {
  local expected="$1"
  shift
  [[ "$(docker_apt_packages)" == "$expected" ]]
}

assert_packages $'docker.io\ndocker-compose-v2'

MOCK_CE=true
assert_packages $'docker-ce\ndocker-ce-cli\ncontainerd.io\ndocker-buildx-plugin\ndocker-compose-plugin'

MOCK_DOCKER=true
MOCK_COMPOSE=true
assert_packages ""

MOCK_COMPOSE=false
assert_packages docker-compose-plugin

MOCK_CE=false
assert_packages docker-compose-v2

printf 'Docker package routing test passed\n'
