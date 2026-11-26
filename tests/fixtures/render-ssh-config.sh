#!/usr/bin/env bash
# Render the Ubuntu SSH config without reading the user's Chezmoi configuration.
set -euo pipefail
root="${1:?repository root required}"
DOTFILES_TERMUX_SSH=0 chezmoi --source "$root" --config /dev/null --config-format yaml \
  execute-template <"$root/private_dot_ssh/private_config.tmpl"
