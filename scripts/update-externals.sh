#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

curl_opts=(-fsSL)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_opts+=(-H "Authorization: token $GITHUB_TOKEN")
fi

update_external() {
  local repo="$1"
  local file="$2"
  local type="${3:-tag}"
  local latest=""

  echo "Checking $repo..."
  if [[ "$type" == "tag" ]]; then
    latest=$(curl "${curl_opts[@]}" "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4 || true)
    if [[ -z "$latest" ]]; then
      latest=$(curl "${curl_opts[@]}" "https://api.github.com/repos/$repo/tags" 2>/dev/null | grep '"name":' | head -n 1 | cut -d '"' -f 4 || true)
    fi
  else
    latest=$(curl "${curl_opts[@]}" "https://api.github.com/repos/$repo/commits/master" 2>/dev/null | grep '"sha":' | head -n 1 | cut -d '"' -f 4 || true)
  fi

  if [[ -n "$latest" ]]; then
    echo "  Latest is $latest"
    # Replace the commit/tag in the URL
    sed -i "s|https://github.com/$repo/archive/.*\.tar\.gz|https://github.com/$repo/archive/$latest.tar.gz|g" "$file"
  else
    echo "  Could not fetch latest for $repo"
  fi
}

external_file="$DOTFILES_DIR/.chezmoiexternal.yaml"
update_external "ohmyzsh/ohmyzsh" "$external_file" "commit"
update_external "zsh-users/zsh-autosuggestions" "$external_file" "tag"
update_external "zsh-users/zsh-syntax-highlighting" "$external_file" "tag"
update_external "Aloxaf/fzf-tab" "$external_file" "tag"
update_external "MichaelAquilina/zsh-you-should-use" "$external_file" "tag"
update_external "tmux-plugins/tpm" "$external_file" "tag"
update_external "junegunn/fzf" "$external_file" "tag"

echo "Done updating $external_file"
