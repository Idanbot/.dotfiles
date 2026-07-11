#!/usr/bin/env bash
# Download and apply every checksum-pinned chezmoi external in isolation.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export DOTFILES_STATE_DIR="$TMP_ROOT/state"
export DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
export DOTFILES_WSL=false
mkdir -p "$HOME" "$TMP_ROOT/destination"

"$DOTFILES_DIR/scripts/install-chezmoi.sh" >/dev/null
export PATH="$HOME/.local/bin:$PATH"
chezmoi init \
  --source="$DOTFILES_DIR" \
  --promptString='Full name=External Smoke' \
  --promptString='Git email=external-smoke@example.invalid' \
  --promptString='tmux-sessionizer search dirs (space-separated)=~/Code'
chezmoi apply \
  --source="$DOTFILES_DIR" \
  --destination="$TMP_ROOT/destination" \
  --include=dirs,externals \
  --force

for target in \
  .oh-my-zsh/oh-my-zsh.sh \
  .oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh \
  .oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
  .oh-my-zsh/custom/plugins/fzf-tab/fzf-tab.plugin.zsh \
  .oh-my-zsh/custom/plugins/you-should-use/you-should-use.plugin.zsh \
  .tmux/plugins/tpm/tpm \
  .fzf/install; do
  [[ -f "$TMP_ROOT/destination/$target" ]] || {
    printf 'External target is missing: %s\n' "$target" >&2
    exit 1
  }
done

printf 'Chezmoi external smoke passed\n'
