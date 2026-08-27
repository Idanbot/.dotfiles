#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export DOTFILES_STATE_DIR="$HOME/.local/state/dotfiles"
export DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
export DOTFILES_OMP_PLUGIN_ROOT="$HOME/.omp/plugins"
mkdir -p "$HOME/.local/bin" "$TMP_ROOT/fixture/ponytail-4.9.0/skills/ponytail"
printf '%s\n' '# Ponytail fixture' >"$TMP_ROOT/fixture/ponytail-4.9.0/skills/ponytail/SKILL.md"
tar -czf "$TMP_ROOT/ponytail.tar.gz" -C "$TMP_ROOT/fixture" ponytail-4.9.0

# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

download_verified() {
  local _url="$1" destination="$2" _checksum="$3" _name="$4"
  cp "$TMP_ROOT/ponytail.tar.gz" "$destination"
}

OMP_CALLS="$TMP_ROOT/omp-calls"
omp() {
  printf '%s\n' "$*" >>"$OMP_CALLS"
  [[ "$1 $2" == 'plugin install' ]]
  local package="${3%@*}" version="${3##*@}" manifest
  manifest="$DOTFILES_OMP_PLUGIN_ROOT/node_modules/$package/package.json"
  mkdir -p "$(dirname "$manifest")"
  jq -n --arg name "$package" --arg version "$version" \
    '{name: $name, version: $version, pi: {extensions: ["./src/index.ts"]}}' >"$manifest"
}

mkdir -p "$HOME/.agents/skills/ponytail"
printf '%s\n' keep >"$HOME/.agents/skills/ponytail/local-note"
install_github_agent_skill ponytail DietrichGebert/ponytail 4.9.0 fixture-sha
grep -Fq '# Ponytail fixture' "$HOME/.agents/skills/ponytail/SKILL.md"
grep -Fxq keep "$HOME/.agents/skills/ponytail/local-note"
grep -Fq $'ponytail\t4.9.0\tagent-skill:DietrichGebert/ponytail' \
  "$DOTFILES_STATE_DIR/installed.tsv"

printf '%s\n' '# Keep local copy' >"$HOME/.agents/skills/ponytail/SKILL.md"
install_github_agent_skill ponytail DietrichGebert/ponytail 4.9.0 fixture-sha
grep -Fq '# Keep local copy' "$HOME/.agents/skills/ponytail/SKILL.md"

omp_install_package @xynogen/pix-optimizer 1.1.26 pix-optimizer
grep -Fxq 'plugin install @xynogen/pix-optimizer@1.1.26' "$OMP_CALLS"
[[ "$(jq -r .version "$DOTFILES_OMP_PLUGIN_ROOT/node_modules/@xynogen/pix-optimizer/package.json")" == 1.1.26 ]]

call_count="$(wc -l <"$OMP_CALLS")"
omp_install_package @xynogen/pix-optimizer 1.1.26 pix-optimizer
[[ "$(wc -l <"$OMP_CALLS")" -eq "$call_count" ]]
grep -Fq $'pix-optimizer\t1.1.26\tomp:@xynogen/pix-optimizer' \
  "$DOTFILES_STATE_DIR/installed.tsv"

initialize_pix_optimizer_state
pix_state="$HOME/.omp/agent/optimizer.json"
jq -e '.caveman == "off" and .rtk == "off" and .ponytail == "off"' "$pix_state" >/dev/null
[[ "$(stat -c %a "$pix_state")" == 600 ]]
jq -n '{caveman: "full", rtk: "on", ponytail: "lite"}' >"$pix_state"
initialize_pix_optimizer_state
jq -e '.caveman == "full" and .rtk == "on" and .ponytail == "lite"' "$pix_state" >/dev/null

printf 'AI optimization package test passed\n'
