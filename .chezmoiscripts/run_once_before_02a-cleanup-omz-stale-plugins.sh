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
  rm -f \
    "$OMZ_PASSCI_DIR/README.md" \
    "$OMZ_PASSCI_DIR/pass-cli.plugin.zsh"
  rmdir --ignore-fail-on-non-empty "$OMZ_PASSCI_DIR" 2>/dev/null || true
  echo "Removed stale pass-cli files from ~/.oh-my-zsh/plugins/"
fi
