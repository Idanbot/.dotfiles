#!/usr/bin/env bash
# Remove pass-cli plugin files that were incorrectly placed inside the OMZ
# upstream plugins tree (~/.oh-my-zsh/plugins/) instead of the custom plugins
# directory. Their presence blocks `omz update` with "untracked working tree
# files would be overwritten by merge".
#
# pass-cli is not an active plugin in this dotfiles setup — these files are
# purely stale artefacts.

OMZ_PASSCI_DIR="${HOME}/.oh-my-zsh/plugins/pass-cli"

if [[ -d "$OMZ_PASSCI_DIR" ]]; then
  backup="$HOME/.local/state/dotfiles/legacy/omz-pass-cli-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$(dirname "$backup")"
  mv "$OMZ_PASSCI_DIR" "$backup"
  echo "Preserved stale pass-cli files at $backup"
fi
