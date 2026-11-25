#!/usr/bin/env bash
# Install or register one explicitly selected agent add-on.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-agent-addons.sh ADDON --agent AGENT
       dot agent-addons ADDON --agent AGENT

  ponytail, caveman, graphify  Shared skills; require --agent all
  omp-ponytail-caveman         Native OMP plugin; --agent omp or all
  context-mode, serena         Register an already-installed MCP server;
                              codex, claude, agy, opencode, omp, or all
EOF
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  usage
  exit 0
fi
if [[ $# != 3 || "$2" != --agent || -z "$3" ]]; then
  usage >&2
  exit 2
fi
addon="$1"
agent="$3"
case "$addon" in
  ponytail | caveman | graphify)
    if [[ "$agent" != all ]]; then
      printf '%s uses a shared skill directory; pass --agent all to opt in.\n' "$addon" >&2
      exit 2
    fi
    ;;
  omp-ponytail-caveman)
    if [[ "$agent" != omp && "$agent" != all ]]; then
      printf '%s only supports OMP.\n' "$addon" >&2
      exit 2
    fi
    ;;
  context-mode | serena) ;;
  *)
    usage >&2
    exit 2
    ;;
esac

DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [[ "$addon" == context-mode || "$addon" == serena ]]; then
  exec bash "$DOTFILES_SOURCE_DIR/dot_local/bin/executable_agent-mcp" enable "$addon" --agent "$agent"
fi
# shellcheck source=scripts/lib.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"

if [[ "$addon" != graphify ]]; then
  key="$addon"
  [[ "$addon" != omp-ponytail-caveman ]] || key=ponytail_caveman
  version="$(package_version ai_tools "$key")"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "No stable repository pin for $addon"
    exit 1
  fi
fi

case "$addon" in
  ponytail)
    install_github_agent_skill ponytail DietrichGebert/ponytail \
      "$version" "$(package_metadata ai_tools ponytail sha256)"
    ;;
  caveman)
    install_github_agent_skill caveman juliusbrussee/caveman \
      "$version" "$(package_metadata ai_tools caveman sha256)"
    ;;
  omp-ponytail-caveman)
    omp_install_package omp-ponytail-caveman "$version" ponytail-caveman
    ;;
  graphify)
    destination="$HOME/.agents/skills/graphify"
    assert_canonical_parent "$destination"
    if [[ -e "$destination" || -L "$destination" ]]; then
      log_skip "Preserving existing Graphify skill at $destination"
    elif command_exists graphify; then
      graphify install --platform agents
    else
      log_error "Graphify CLI is required; install the AI tools first"
      exit 1
    fi
    ;;
esac
