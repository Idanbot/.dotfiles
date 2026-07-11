#!/usr/bin/env bash
# Update chezmoi external refs and their SHA256 pins as one transaction.

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MODE=check
case "${1:-}" in
  --apply) MODE=apply ;;
  --check | '') MODE=check ;;
  -h | --help)
    printf 'Usage: scripts/update-externals.sh [--check|--apply]\n'
    exit 0
    ;;
  *)
    printf 'Unknown option: %s\n' "$1" >&2
    exit 2
    ;;
esac

SOURCE="$DOTFILES_DIR/.chezmoiexternal.yaml"
WORK="$(mktemp)"
cp "$SOURCE" "$WORK"
trap 'rm -f "$WORK"' EXIT

curl_args=(--proto '=https' --tlsv1.2 --retry 3 -fsSL)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

latest_release() {
  curl "${curl_args[@]}" "https://api.github.com/repos/$1/releases/latest" |
    sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

latest_commit() {
  local repo="$1" metadata branch
  metadata="$(curl "${curl_args[@]}" "https://api.github.com/repos/$repo")"
  branch="$(sed -n 's/.*"default_branch":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$metadata" | head -1)"
  curl "${curl_args[@]}" "https://api.github.com/repos/$repo/commits/$branch" |
    sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]*\)".*/\1/p' | head -1
}

update_entry() {
  local target="$1" repo="$2" ref_type="$3" ref url tmp sha
  if [[ "$ref_type" == commit ]]; then
    ref="$(latest_commit "$repo")"
  else
    ref="$(latest_release "$repo")"
  fi
  [[ -n "$ref" ]] || {
    printf 'Could not resolve %s\n' "$repo" >&2
    return 1
  }
  url="https://github.com/$repo/archive/$ref.tar.gz"
  tmp="$(mktemp)"
  curl "${curl_args[@]}" -o "$tmp" "$url"
  sha="$(sha256sum "$tmp" | awk '{print $1}')"
  rm -f "$tmp"

  python3 - "$WORK" "$target" "$url" "$sha" <<'PY'
import sys
from pathlib import Path

path, target, url, sha = sys.argv[1:]
lines = Path(path).read_text(encoding="utf-8").splitlines()
header = f'"{target}":'
inside = False
for i, line in enumerate(lines):
    if line == header:
        inside = True
        continue
    if inside and line and not line.startswith(" "):
        break
    if inside and line.lstrip().startswith("url:"):
        lines[i] = f'  url: "{url}"'
    if inside and line.lstrip().startswith("sha256:"):
        lines[i] = f'    sha256: "{sha}"'
Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
  printf '%s -> %s\n' "$target" "$ref"
}

update_entry .oh-my-zsh ohmyzsh/ohmyzsh commit
update_entry .oh-my-zsh/custom/plugins/zsh-autosuggestions zsh-users/zsh-autosuggestions release
update_entry .oh-my-zsh/custom/plugins/zsh-syntax-highlighting zsh-users/zsh-syntax-highlighting release
update_entry .oh-my-zsh/custom/plugins/fzf-tab Aloxaf/fzf-tab release
update_entry .oh-my-zsh/custom/plugins/you-should-use MichaelAquilina/zsh-you-should-use release
update_entry .tmux/plugins/tpm tmux-plugins/tpm release
update_entry .fzf junegunn/fzf release

if cmp -s "$SOURCE" "$WORK"; then
  printf 'External pins are current\n'
  exit 0
fi
if [[ "$MODE" == apply ]]; then
  cp "$WORK" "$SOURCE"
  printf 'Updated external refs and checksums\n'
else
  diff -u "$SOURCE" "$WORK" || true
  exit 3
fi
