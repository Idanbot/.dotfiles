#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
INSTALL="$DOTFILES_DIR/scripts/install.sh"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

for profile in minimal base developer agent cloud full; do
  file="$DOTFILES_DIR/profiles/$profile.conf"
  [[ -f "$file" ]]
  grep -Fxq "name=$profile" "$file"
  sections="$(sed -n 's/^sections=//p' "$file")"
  output="$($INSTALL --profile "$profile" --print-plan)"
  grep -Fxq "profile=$profile" <<<"$output"
  grep -Fxq "sections=$sections" <<<"$output"
  standalone="$(cd "$temporary" && HOME="$temporary" DOTFILES_SOURCE_OVERRIDE='' bash -s -- --profile "$profile" --print-plan <"$INSTALL")"
  [[ "$standalone" == "$output" ]]
done

[[ "$("$INSTALL" --full --print-plan)" == "$("$INSTALL" --profile full --print-plan)" ]]

full_count="$(tr ',' '\n' < <(sed -n 's/^sections=//p' "$DOTFILES_DIR/profiles/full.conf") | wc -l)"
[[ "$full_count" -eq 17 ]]

printf 'Profile test passed\n'
