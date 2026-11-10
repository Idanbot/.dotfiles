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
mkdir -p "$TMP_ROOT/fixture/caveman-4.1.0/skills/caveman"
printf '%s\n' '# Caveman fixture' >"$TMP_ROOT/fixture/caveman-4.1.0/skills/caveman/SKILL.md"
tar -czf "$TMP_ROOT/caveman.tar.gz" -C "$TMP_ROOT/fixture" caveman-4.1.0

# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

download_verified() {
  local url="$1" destination="$2" _checksum="$3" _name="$4"
  [[ "${DOWNLOAD_FORCE_FAIL:-false}" != true ]] || return 1
  case "$url" in
    */juliusbrussee/caveman/*) cp "$TMP_ROOT/caveman.tar.gz" "$destination" ;;
    */DietrichGebert/ponytail/*) cp "$TMP_ROOT/ponytail.tar.gz" "$destination" ;;
    *) return 1 ;;
  esac
}

export OMP_CALLS="$TMP_ROOT/omp-calls"
cat >"$HOME/.local/bin/omp" <<'OMP'
#!/usr/bin/env bash
set -euo pipefail
  printf '%s\n' "$*" >>"$OMP_CALLS"
  [[ "${OMP_FORCE_FAIL:-false}" != true ]] || exit 37
  if [[ "$1 $2" == 'plugin uninstall' ]]; then
    [[ "${OMP_KEEP_PLUGIN:-false}" != true ]] || exit 0
    rm -rf "$DOTFILES_OMP_PLUGIN_ROOT/node_modules/$3"
    if [[ -f "$DOTFILES_OMP_PLUGIN_ROOT/package.json" && "${OMP_KEEP_DECLARATION:-false}" != true ]]; then
      jq --arg package "$3" 'del(.dependencies[$package])' "$DOTFILES_OMP_PLUGIN_ROOT/package.json" >"$DOTFILES_OMP_PLUGIN_ROOT/package.json.new"
      mv "$DOTFILES_OMP_PLUGIN_ROOT/package.json.new" "$DOTFILES_OMP_PLUGIN_ROOT/package.json"
    fi
    exit 0
  fi
  [[ "$1 $2" == 'plugin install' ]]
  package="${3%@*}" version="${3##*@}"
  [[ "${OMP_WRONG_VERSION:-false}" != true ]] || version=0.0.0
  manifest=""
  manifest="$DOTFILES_OMP_PLUGIN_ROOT/node_modules/$package/package.json"
  mkdir -p "$(dirname "$manifest")"
  jq -n --arg name "$package" --arg version "$version" \
    '{name: $name, version: $version, pi: {extensions: ["./src/index.ts"]}}' >"$manifest"
  [[ "${OMP_PARTIAL_FAIL:-false}" != true ]] || exit 37
OMP
chmod +x "$HOME/.local/bin/omp"
export PATH="$HOME/.local/bin:$PATH"

mkdir -p "$HOME/.agents/skills/ponytail"
printf '%s\n' keep >"$HOME/.agents/skills/ponytail/local-note"
printf '%s\n' 'local configuration' >"$HOME/.agents/skills/ponytail/config.json"
install_github_agent_skill ponytail DietrichGebert/ponytail 4.9.0 fixture-sha
[[ ! -e "$HOME/.agents/skills/ponytail/SKILL.md" ]]
grep -Fxq keep "$HOME/.agents/skills/ponytail/local-note"
grep -Fxq 'local configuration' "$HOME/.agents/skills/ponytail/config.json"
[[ ! -f "$DOTFILES_STATE_DIR/installed.tsv" ]]
rm -rf "$HOME/.agents/skills/ponytail"
mkdir -p "$TMP_ROOT/external-skill"
ln -s "$TMP_ROOT/external-skill" "$HOME/.agents/skills/ponytail"
install_github_agent_skill ponytail DietrichGebert/ponytail 4.9.0 fixture-sha
[[ ! -e "$TMP_ROOT/external-skill/SKILL.md" ]]
rm "$HOME/.agents/skills/ponytail"
export DOWNLOAD_FORCE_FAIL=true
if install_github_agent_skill ponytail DietrichGebert/ponytail 4.9.0 fixture-sha; then
  printf 'Failed verified download was ignored\n' >&2
  exit 1
fi
unset DOWNLOAD_FORCE_FAIL
[[ ! -e "$HOME/.agents/skills/ponytail" ]]
install_github_agent_skill ponytail DietrichGebert/ponytail 4.9.0 fixture-sha
grep -Fq '# Ponytail fixture' "$HOME/.agents/skills/ponytail/SKILL.md"
grep -Fq $'ponytail\t4.9.0\tagent-skill:DietrichGebert/ponytail' \
  "$DOTFILES_STATE_DIR/installed.tsv"

printf '%s\n' '# Keep local copy' >"$HOME/.agents/skills/ponytail/SKILL.md"
install_github_agent_skill ponytail DietrichGebert/ponytail 4.9.0 fixture-sha
grep -Fq '# Keep local copy' "$HOME/.agents/skills/ponytail/SKILL.md"
install_github_agent_skill caveman juliusbrussee/caveman 4.1.0 fixture-sha
grep -Fxq '# Caveman fixture' "$HOME/.agents/skills/caveman/SKILL.md"
printf '%s\n' '# Local Caveman choice' >"$HOME/.agents/skills/caveman/SKILL.md"
caveman_digest="$(managed_target_digest "$HOME/.agents/skills/caveman")"
install_github_agent_skill caveman juliusbrussee/caveman 4.1.0 fixture-sha
[[ "$(managed_target_digest "$HOME/.agents/skills/caveman")" == "$caveman_digest" ]]

omp_install_package omp-ponytail-caveman 0.3.4 ponytail-caveman
grep -Fxq 'plugin install omp-ponytail-caveman@0.3.4' "$OMP_CALLS"
[[ "$(jq -r .version "$DOTFILES_OMP_PLUGIN_ROOT/node_modules/omp-ponytail-caveman/package.json")" == 0.3.4 ]]

call_count="$(wc -l <"$OMP_CALLS")"
omp_install_package omp-ponytail-caveman 0.3.4 ponytail-caveman
[[ "$(wc -l <"$OMP_CALLS")" -eq "$call_count" ]]
omp_plugin_is_validated omp-ponytail-caveman
printf '# active OMP changed\n' >>"$HOME/.local/bin/omp"
if omp_plugin_is_validated omp-ponytail-caveman; then
  printf 'Stale compatibility validation was accepted\n' >&2
  exit 1
fi
omp_install_package omp-ponytail-caveman 0.3.4 ponytail-caveman
omp_plugin_is_validated omp-ponytail-caveman
call_count="$(wc -l <"$OMP_CALLS")"
grep -Fq $'ponytail-caveman\t0.3.4\tomp:omp-ponytail-caveman' \
  "$DOTFILES_STATE_DIR/installed.tsv"

export OMP_FORCE_FAIL=true
if omp_install_package omp-ponytail-caveman 0.3.5 ponytail-caveman; then
  printf 'Native extension validation failure was ignored\n' >&2
  exit 1
fi
unset OMP_FORCE_FAIL
before="$(managed_target_digest "$DOTFILES_OMP_PLUGIN_ROOT")"
export OMP_PARTIAL_FAIL=true
if omp_install_package omp-ponytail-caveman 0.3.5 ponytail-caveman; then
  printf 'Partial mutation failure was ignored\n' >&2
  exit 1
fi
unset OMP_PARTIAL_FAIL
[[ "$(managed_target_digest "$DOTFILES_OMP_PLUGIN_ROOT")" == "$before" ]]
target_is_owned "$DOTFILES_OMP_PLUGIN_ROOT/node_modules/omp-ponytail-caveman"
omp_plugin_is_validated omp-ponytail-caveman
export OMP_WRONG_VERSION=true
if omp_install_package omp-ponytail-caveman 0.3.5 ponytail-caveman; then
  printf 'Wrong-version candidate was accepted\n' >&2
  exit 1
fi
unset OMP_WRONG_VERSION
[[ "$(managed_target_digest "$DOTFILES_OMP_PLUGIN_ROOT")" == "$before" ]]
target_is_owned "$DOTFILES_OMP_PLUGIN_ROOT/node_modules/omp-ponytail-caveman"
grep -Fq $'ponytail-caveman\t0.3.4\tomp:omp-ponytail-caveman' \
  "$DOTFILES_STATE_DIR/installed.tsv"
call_count="$(wc -l <"$OMP_CALLS")"

retired="$DOTFILES_OMP_PLUGIN_ROOT/node_modules/@xynogen/pix-optimizer"
mkdir -p "$retired"
printf '{}' >"$retired/package.json"
record_install pix-optimizer 1.3.5 omp:@xynogen/pix-optimizer "$retired"
plugin_settings="$DOTFILES_OMP_PLUGIN_ROOT/package.json"
printf '%s\n' '{"dependencies":{"other":"2.0.0"},"overrides":{"@xynogen/pix-pretty":"1.30.0","other":"3.0.0"}}' >"$plugin_settings"
mkdir -p "$DOTFILES_OMP_PLUGIN_ROOT/node_modules/other"
printf '%s\n' keep >"$DOTFILES_OMP_PLUGIN_ROOT/node_modules/other/local-file"
settings_digest="$(managed_target_digest "$plugin_settings")"
other_digest="$(managed_target_digest "$DOTFILES_OMP_PLUGIN_ROOT/node_modules/other")"
export OMP_FORCE_FAIL=true
if remove_retired_omp_optimizer; then
  printf 'Uninstall failure was ignored\n' >&2
  exit 1
fi
unset OMP_FORCE_FAIL
[[ -d "$retired" ]]
grep -q '^pix-optimizer' "$DOTFILES_STATE_DIR/installed.tsv"
[[ "$(managed_target_digest "$plugin_settings")" == "$settings_digest" ]]
export OMP_KEEP_PLUGIN=true
if remove_retired_omp_optimizer; then
  printf 'Incomplete uninstall was ignored\n' >&2
  exit 1
fi
unset OMP_KEEP_PLUGIN
remove_retired_omp_optimizer
[[ ! -e "$retired" ]]
[[ "$(managed_target_digest "$DOTFILES_OMP_PLUGIN_ROOT/node_modules/other")" == "$other_digest" ]]
jq -e '.dependencies.other == "2.0.0" and .overrides == {"other":"3.0.0"}' "$plugin_settings" >/dev/null
[[ -f "$DOTFILES_OMP_PLUGIN_ROOT/node_modules/omp-ponytail-caveman/package.json" ]]
! grep -q '^pix-optimizer' "$DOTFILES_STATE_DIR/installed.tsv"
call_count="$(wc -l <"$OMP_CALLS")"
settings_digest="$(managed_target_digest "$plugin_settings")"
remove_retired_omp_optimizer
[[ "$(wc -l <"$OMP_CALLS")" -eq "$call_count" ]]
[[ "$(managed_target_digest "$plugin_settings")" == "$settings_digest" ]]

redirected="$TMP_ROOT/redirected-plugins"
printf '%s\n' '{"dependencies":{"@xynogen/pix-optimizer":"1.3.7","other":"2.0.0"}}' >"$plugin_settings"
settings_digest="$(managed_target_digest "$plugin_settings")"
export OMP_KEEP_DECLARATION=true
if remove_retired_omp_optimizer; then
  printf 'Retained Pix declaration was accepted\n' >&2
  exit 1
fi
unset OMP_KEEP_DECLARATION
[[ "$(managed_target_digest "$plugin_settings")" == "$settings_digest" ]]
remove_retired_omp_optimizer
jq -e '.dependencies == {"other":"2.0.0"}' "$plugin_settings" >/dev/null
call_count="$(wc -l <"$OMP_CALLS")"
ln -s "$DOTFILES_OMP_PLUGIN_ROOT" "$redirected"
if DOTFILES_OMP_PLUGIN_ROOT="$redirected" remove_retired_omp_optimizer; then
  printf 'Redirected plugin directory was accepted\n' >&2
  exit 1
fi
[[ "$(wc -l <"$OMP_CALLS")" -eq "$call_count" ]]

# Exercise the actual installer block so metadata migrations cannot empty its asset.
awk '/^RTK_VERSION=/ { block = 1 } /^PONYTAIL_VERSION=/ { exit } block' \
  "$DOTFILES_DIR/.chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl" >"$TMP_ROOT/rtk.sh"
rtk_calls=0
install_github_archive() {
  [[ "$1" == rtk && "$2" == rtk-ai/rtk && "$3" == "v$RTK_VERSION" ]]
  [[ "$4" == "$expected_asset" && "$5" == rtk ]]
  [[ "$6" =~ ^sha256:[0-9a-f]{64}$ ]]
  rtk_calls=$((rtk_calls + 1))
}
for architecture in amd64 arm64; do
  get_arch() { printf '%s\n' "$architecture"; }
  case "$architecture" in
    amd64) expected_asset=rtk-x86_64-unknown-linux-musl.tar.gz ;;
    arm64) expected_asset=rtk-aarch64-unknown-linux-gnu.tar.gz ;;
  esac
  source "$TMP_ROOT/rtk.sh"
done
[[ "$rtk_calls" == 2 ]]

printf 'AI optimization package test passed\n'

for scenario in external modified; do
  (
    export HOME="$TMP_ROOT/omp-preserve-$scenario"
    export DOTFILES_STATE_DIR="$HOME/state" DOTFILES_OMP_PLUGIN_ROOT="$HOME/.omp/plugins"
    source "$DOTFILES_DIR/scripts/lib.sh"
    plugin="$DOTFILES_OMP_PLUGIN_ROOT/node_modules/omp-ponytail-caveman"
    mkdir -p "$plugin"
    printf '{"name":"omp-ponytail-caveman","version":"0.3.4"}\n' >"$plugin/package.json"
    if [[ "$scenario" == modified ]]; then
      record_install ponytail-caveman 0.3.4 omp:omp-ponytail-caveman "$plugin"
      printf 'local note\n' >"$plugin/local-note"
    fi
    before="$(managed_target_digest "$plugin")"
    ledger_before="$(managed_target_digest "$DOTFILES_STATE_DIR/installed.tsv")"
    calls_before="$(wc -l <"$OMP_CALLS")"
    omp_install_package omp-ponytail-caveman 0.3.5 ponytail-caveman
    [[ "$(managed_target_digest "$plugin")" == "$before" ]]
    [[ "$(managed_target_digest "$DOTFILES_STATE_DIR/installed.tsv")" == "$ledger_before" ]]
    [[ "$(wc -l <"$OMP_CALLS")" == "$calls_before" ]]
    [[ "$_FAILED" == 0 && "$_PRESERVED" == 1 ]]
    print_summary "Preserved OMP plugin"
  )
done
