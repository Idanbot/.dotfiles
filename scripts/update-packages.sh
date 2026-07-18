#!/usr/bin/env bash
# Audit upstream versions and integrity, then apply explicitly accepted updates.

set -euo pipefail

DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PACKAGES_FILE="${DOTFILES_PACKAGES_FILE:-$DOTFILES_SOURCE_DIR/packages.yaml}"
META_FILE="${DOTFILES_META_FILE:-$DOTFILES_SOURCE_DIR/packages.meta.yaml}"
EXTERNALS_FILE="${DOTFILES_EXTERNALS_FILE:-$DOTFILES_SOURCE_DIR/.chezmoiexternal.yaml}"
REPORT="${DOTFILES_UPDATE_REPORT:-$DOTFILES_SOURCE_DIR/.version-update-report}"
MODE=check
APPLY_ALL=false
FAIL_ON_UPDATES=false
REPORT_EXPLICIT=false
TARGETS=()

usage() {
  cat <<'EOF'
Usage:
  scripts/update-packages.sh --check [--report PATH]
  scripts/update-packages.sh --apply-all [--report PATH]
  scripts/update-packages.sh --apply SECTION.TOOL[@VERSION] [...] [--report PATH]

Options:
  --check             Report available updates without changing files (default).
  --apply-all         Apply every fully verified update in the report.
  --apply TOOL...     Apply named updates; @VERSION pins the reviewed candidate.
  --report PATH       Write the Markdown report to PATH.
  --fail-on-updates   Return exit status 3 when check mode finds updates.
  -h, --help          Show this help.

All apply modes update packages.yaml, pinned checksums in packages.meta.yaml,
packages.lock, and docs/tool-inventory.md as one reviewed change set.
EOF
}

die() {
  printf 'update-packages: %s\n' "$*" >&2
  exit 2
}

while (($#)); do
  case "$1" in
    --check)
      MODE=check
      shift
      ;;
    --apply-all)
      MODE=apply
      APPLY_ALL=true
      shift
      ;;
    --apply)
      MODE=apply
      APPLY_ALL=false
      shift
      while (($#)) && [[ "$1" != --* ]]; do
        TARGETS+=("$1")
        shift
      done
      ((${#TARGETS[@]} > 0)) || die "--apply requires at least one SECTION.TOOL"
      ;;
    --report)
      (($# >= 2)) || die "--report requires a path"
      REPORT="$2"
      REPORT_EXPLICIT=true
      shift 2
      ;;
    --fail-on-updates)
      FAIL_ON_UPDATES=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option or target: $1" ;;
  esac
done

[[ -f "$PACKAGES_FILE" ]] || die "missing package manifest: $PACKAGES_FILE"
[[ -f "$META_FILE" ]] || die "missing package metadata: $META_FILE"

export DOTFILES_PACKAGES_FILE="$PACKAGES_FILE"
export DOTFILES_PACKAGES_META_FILE="$META_FILE"
# shellcheck source=scripts/lib.sh
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"

if [[ "$REPORT_EXPLICIT" == false && "$REPORT" == "$DOTFILES_SOURCE_DIR/.version-update-report" ]]; then
  REPORT="${DOTFILES_UPDATE_REPORT:-$DOTFILES_SOURCE_DIR/.version-update-report}"
fi
mkdir -p "$(dirname "$REPORT")"

WORK_DIR="$(mktemp -d)"
PLAN="$WORK_DIR/upgrade-plan.tsv"
WARNINGS="$WORK_DIR/warnings"
touch "$PLAN" "$WARNINGS"
trap 'rm -rf "$WORK_DIR"' EXIT

CURL_ARGS=(--proto '=https' --tlsv1.2 --retry 3 --retry-all-errors -fsSL)
GITHUB_API_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$GITHUB_API_TOKEN" ]] && command -v gh >/dev/null 2>&1; then
  GITHUB_API_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [[ -n "$GITHUB_API_TOKEN" ]]; then
  GITHUB_HEADERS=(-H "Authorization: Bearer $GITHUB_API_TOKEN")
else
  GITHUB_HEADERS=()
fi

metadata_value() {
  package_metadata "$1" "$2" "$3"
}

wanted() {
  local id="$1" target target_id
  [[ "$MODE" == check || "$APPLY_ALL" == true ]] && return 0
  for target in "${TARGETS[@]}"; do
    target_id="${target%@*}"
    [[ "$target_id" == "$id" ]] && return 0
  done
  return 1
}

requested_version() {
  local id="$1" target target_id
  for target in "${TARGETS[@]}"; do
    target_id="${target%@*}"
    if [[ "$target_id" == "$id" && "$target" == *@* ]]; then
      printf '%s\n' "${target#*@}"
      return 0
    fi
  done
  return 1
}

warn() {
  printf '%s\n' "$*" >>"$WARNINGS"
  log_warn "$*"
}

github_release_json() {
  local repo="$1" tag="$2" cache safe_repo safe_tag
  safe_repo="${repo//\//_}"
  safe_tag="${tag//\//_}"
  cache="$WORK_DIR/release-${safe_repo}-${safe_tag}.json"
  if [[ ! -s "$cache" ]]; then
    curl "${CURL_ARGS[@]}" "${GITHUB_HEADERS[@]}" \
      "https://api.github.com/repos/$repo/releases/tags/$tag" >"$cache"
  fi
  printf '%s\n' "$cache"
}

github_latest_version() {
  local repo="$1" tag
  tag="$(curl "${CURL_ARGS[@]}" "${GITHUB_HEADERS[@]}" \
    "https://api.github.com/repos/$repo/releases/latest" | jq -r .tag_name)"
  printf '%s\n' "${tag#v}"
}

npm_version() {
  local package="$1" version="${2:-latest}" encoded
  encoded="${package//\//%2f}"
  curl "${CURL_ARGS[@]}" "https://registry.npmjs.org/$encoded/$version" | jq -r .version
}

npm_integrity() {
  local package="$1" version="$2" encoded
  encoded="${package//\//%2f}"
  curl "${CURL_ARGS[@]}" "https://registry.npmjs.org/$encoded/$version" |
    jq -r '.dist.integrity // ("sha1:" + .dist.shasum)'
}

pypi_version() {
  curl "${CURL_ARGS[@]}" "https://pypi.org/pypi/$1/json" | jq -r .info.version
}

pypi_integrity() {
  local package="$1" version="$2" digest
  digest="$(curl "${CURL_ARGS[@]}" "https://pypi.org/pypi/$package/$version/json" |
    jq -r '[.urls[].digests.sha256] | sort | join("\n")' | sha256sum | awk '{print $1}')"
  printf 'pypi-set:%s\n' "$digest"
}

github_asset_spec() {
  local id="$1"
  case "$id" in
    bootstrap.chezmoi) printf '%s\n' 'twpayne/chezmoi|v{version}|chezmoi_{version}_linux_{arch}.tar.gz|amd64|arm64' ;;
    core.eza) printf '%s\n' 'eza-community/eza|v{version}|eza_{arch}-unknown-linux-gnu.tar.gz|x86_64|aarch64' ;;
    core.lazygit) printf '%s\n' 'jesseduffield/lazygit|v{version}|lazygit_{version}_linux_{arch}.tar.gz|x86_64|arm64' ;;
    core.starship) printf '%s\n' 'starship/starship|v{version}|starship-{arch}-unknown-linux-gnu.tar.gz|x86_64|aarch64' ;;
    core.sops) printf '%s\n' 'getsops/sops|v{version}|sops-v{version}.linux.{arch}|amd64|arm64' ;;
    core.lazydocker) printf '%s\n' 'jesseduffield/lazydocker|v{version}|lazydocker_{version}_Linux_{arch}.tar.gz|x86_64|arm64' ;;
    core.tealdeer) printf '%s\n' 'dbrgn/tealdeer|v{version}|tealdeer-linux-{arch}-musl|x86_64|aarch64' ;;
    languages.uv) printf '%s\n' 'astral-sh/uv|{version}|uv-{arch}-unknown-linux-gnu.tar.gz|x86_64|aarch64' ;;
    history.atuin) printf '%s\n' 'atuinsh/atuin|v{version}|atuin-{arch}-unknown-linux-gnu.tar.gz|x86_64|aarch64' ;;
    editor.neovim) printf '%s\n' 'neovim/neovim|v{version}|nvim-linux-{arch}.tar.gz|x86_64|arm64' ;;
    cloud.k9s) printf '%s\n' 'derailed/k9s|v{version}|k9s_Linux_{arch}.tar.gz|amd64|arm64' ;;
    fonts.nerd_font_version)
      printf 'ryanoasis/nerd-fonts|v{version}|%s.zip|shared|shared\n' \
        "$(package_version fonts nerd_font FiraMono)"
      ;;
    terminal.herdr) printf '%s\n' 'ogulcancelik/herdr|v{version}|herdr-linux-{arch}|x86_64|aarch64' ;;
    system.git_credential_manager) printf '%s\n' 'git-ecosystem/git-credential-manager|v{version}|gcm-linux-{arch}-{version}.deb|x64|arm64' ;;
    ai_tools.omp) printf '%s\n' 'can1357/oh-my-pi|v{version}|omp-linux-{arch}|x64|arm64' ;;
    media.rmpc) printf '%s\n' 'mierak/rmpc|v{version}|rmpc-v{version}-{arch}-unknown-linux-gnu.tar.gz|x86_64|aarch64' ;;
    *) return 1 ;;
  esac
}

render_template() {
  local template="$1" version="$2" arch="$3"
  template="${template//\{version\}/$version}"
  template="${template//\{arch\}/$arch}"
  printf '%s\n' "$template"
}

github_asset_sha() {
  local repo="$1" tag="$2" asset="$3" json digest url tmp
  json="$(github_release_json "$repo" "$tag")"
  digest="$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // empty' "$json")"
  if [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
    printf '%s\n' "${digest#sha256:}"
    return 0
  fi
  url="$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .browser_download_url // empty' "$json")"
  [[ -n "$url" ]] || return 1
  tmp="$WORK_DIR/asset-$(sha256sum <<<"$repo/$tag/$asset" | awk '{print $1}')"
  [[ -s "$tmp" ]] || curl "${CURL_ARGS[@]}" "${GITHUB_HEADERS[@]}" -o "$tmp" "$url"
  sha256sum "$tmp" | awk '{print $1}'
}

github_checksums() {
  local id="$1" version="$2" spec repo tag_template asset_template amd_arch arm_arch tag amd_asset arm_asset
  local amd_sha arm_sha
  spec="$(github_asset_spec "$id")" || return 1
  IFS='|' read -r repo tag_template asset_template amd_arch arm_arch <<<"$spec"
  tag="$(render_template "$tag_template" "$version" '')"
  amd_asset="$(render_template "$asset_template" "$version" "$amd_arch")"
  arm_asset="$(render_template "$asset_template" "$version" "$arm_arch")"
  amd_sha="$(github_asset_sha "$repo" "$tag" "$amd_asset")" || return 1
  arm_sha="$(github_asset_sha "$repo" "$tag" "$arm_asset")" || return 1
  printf 'amd64:%s;arm64:%s\n' "$amd_sha" "$arm_sha"
}

pinned_metadata_checksums() {
  local section="$1" key="$2" sha amd arm
  sha="$(metadata_value "$section" "$key" sha256)"
  if [[ -n "$sha" ]]; then
    printf 'sha256:%s\n' "$sha"
    return 0
  fi
  amd="$(metadata_value "$section" "$key" sha256_amd64)"
  arm="$(metadata_value "$section" "$key" sha256_arm64)"
  [[ -n "$amd" && -n "$arm" ]] || return 1
  printf 'amd64:%s;arm64:%s\n' "$amd" "$arm"
}

external_archive_checksum() {
  local repo="$1" tag="$2" tmp
  tmp="$WORK_DIR/archive-$(sha256sum <<<"$repo/$tag" | awk '{print $1}')"
  [[ -s "$tmp" ]] || curl "${CURL_ARGS[@]}" "${GITHUB_HEADERS[@]}" \
    -o "$tmp" "https://github.com/$repo/archive/$tag.tar.gz"
  sha256sum "$tmp" | awk '{print $1}'
}

direct_checksums() {
  local id="$1" version="$2" amd arm asset sums base
  case "$id" in
    languages.go)
      sums="$(curl "${CURL_ARGS[@]}" 'https://go.dev/dl/?mode=json&include=all')"
      amd="$(jq -r --arg asset "go${version}.linux-amd64.tar.gz" '[.[] | .files[] | select(.filename == $asset) | .sha256][0] // empty' <<<"$sums")"
      arm="$(jq -r --arg asset "go${version}.linux-arm64.tar.gz" '[.[] | .files[] | select(.filename == $asset) | .sha256][0] // empty' <<<"$sums")"
      ;;
    languages.node_lts)
      sums="$(curl "${CURL_ARGS[@]}" "https://nodejs.org/dist/v${version}/SHASUMS256.txt")"
      amd="$(checksum_for_asset /dev/stdin "node-v${version}-linux-x64.tar.xz" <<<"$sums")"
      arm="$(checksum_for_asset /dev/stdin "node-v${version}-linux-arm64.tar.xz" <<<"$sums")"
      ;;
    cloud.kubectl)
      amd="$(curl "${CURL_ARGS[@]}" "https://dl.k8s.io/release/v${version}/bin/linux/amd64/kubectl.sha256")"
      arm="$(curl "${CURL_ARGS[@]}" "https://dl.k8s.io/release/v${version}/bin/linux/arm64/kubectl.sha256")"
      ;;
    cloud.helm)
      amd="$(curl "${CURL_ARGS[@]}" "https://get.helm.sh/helm-v${version}-linux-amd64.tar.gz.sha256sum" | awk '{print $1}')"
      arm="$(curl "${CURL_ARGS[@]}" "https://get.helm.sh/helm-v${version}-linux-arm64.tar.gz.sha256sum" | awk '{print $1}')"
      ;;
    cloud.terraform)
      base="https://releases.hashicorp.com/terraform/${version}"
      sums="$(curl "${CURL_ARGS[@]}" "$base/terraform_${version}_SHA256SUMS")"
      amd="$(checksum_for_asset /dev/stdin "terraform_${version}_linux_amd64.zip" <<<"$sums")"
      arm="$(checksum_for_asset /dev/stdin "terraform_${version}_linux_arm64.zip" <<<"$sums")"
      ;;
    *) return 1 ;;
  esac
  [[ "$amd" =~ ^[0-9a-fA-F]{64}$ && "$arm" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf 'amd64:%s;arm64:%s\n' "$amd" "$arm"
}

integrity_pair() {
  local id="$1" section="$2" key="$3" current="$4" latest="$5" integrity package old new
  integrity="$(metadata_value "$section" "$key" integrity)"
  if [[ "$id" == core.fzf ]]; then
    if old="$(external_archive_checksum junegunn/fzf "v$current")"; then
      old="sha256:$old"
    else
      old=unresolved
    fi
    if new="$(external_archive_checksum junegunn/fzf "v$latest")"; then
      new="sha256:$new"
    else
      new=unresolved
    fi
    printf '%s\t%s\n' "$old" "$new"
    return 0
  fi
  case "$integrity" in
    pinned-sha256)
      old="$(pinned_metadata_checksums "$section" "$key")" || old=unresolved
      if github_asset_spec "$id" >/dev/null; then
        new="$(github_checksums "$id" "$latest")" || new=unresolved
      else
        new=manual-refresh-required
      fi
      ;;
    npm-registry)
      package="$(metadata_value "$section" "$key" package)"
      old="$(npm_integrity "$package" "$current")" || old=unresolved
      new="$(npm_integrity "$package" "$latest")" || new=unresolved
      ;;
    pypi)
      package="$(metadata_value "$section" "$key" package)"
      old="$(pypi_integrity "$package" "$current")" || old=unresolved
      new="$(pypi_integrity "$package" "$latest")" || new=unresolved
      ;;
    upstream-checksum)
      if github_asset_spec "$id" >/dev/null; then
        old="$(github_checksums "$id" "$current")" || old=unresolved
        new="$(github_checksums "$id" "$latest")" || new=unresolved
      elif direct_checksums "$id" "$current" >/dev/null 2>&1; then
        old="$(direct_checksums "$id" "$current")" || old=unresolved
        new="$(direct_checksums "$id" "$latest")" || new=unresolved
      else
        old=upstream-managed
        new=upstream-managed
      fi
      ;;
    *)
      old="$integrity"
      new="$integrity"
      ;;
  esac
  printf '%s\t%s\n' "$old" "$new"
}

add_candidate() {
  local section="$1" key="$2" latest="$3" old_integrity="${4:-}" new_integrity="${5:-}"
  local force="${6:-false}" id current integrity pair accepted_version
  id="$section.$key"
  wanted "$id" || return 0
  current="$(package_version "$section" "$key")"
  latest="${latest#v}"
  accepted_version="$(requested_version "$id" 2>/dev/null || true)"
  [[ -z "$accepted_version" ]] || latest="${accepted_version#v}"
  [[ -n "$latest" && "$latest" != null ]] || {
    warn "Could not resolve latest version for $id"
    return 0
  }
  if [[ "$force" != true ]] && { version_equals "$current" "$latest" || version_ge "$current" "$latest"; }; then
    return 0
  fi
  if [[ "$force" == true && "$old_integrity" == "$new_integrity" ]]; then
    return 0
  fi
  integrity="$(metadata_value "$section" "$key" integrity)"
  if [[ -z "$old_integrity" || -z "$new_integrity" ]]; then
    pair="$(integrity_pair "$id" "$section" "$key" "$current" "$latest")"
    IFS=$'\t' read -r old_integrity new_integrity <<<"$pair"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$section" "$key" "$current" "$latest" "$integrity" \
    "$old_integrity -> $new_integrity" >>"$PLAN"
}

audit_github() {
  local section="$1" key="$2" repo="$3" latest
  wanted "$section.$key" || return 0
  latest="$(github_latest_version "$repo" 2>/dev/null)" || latest=""
  add_candidate "$section" "$key" "$latest"
}

audit_npm() {
  local section="$1" key="$2" package="$3" latest
  wanted "$section.$key" || return 0
  latest="$(npm_version "$package" 2>/dev/null)" || latest=""
  add_candidate "$section" "$key" "$latest"
}

audit_pypi() {
  local section="$1" key="$2" package="$3" latest
  wanted "$section.$key" || return 0
  latest="$(pypi_version "$package" 2>/dev/null)" || latest=""
  add_candidate "$section" "$key" "$latest"
}

audit_mutable_url() {
  local section="$1" key="$2" url="$3" id old_sha new_sha tmp
  id="$section.$key"
  wanted "$id" || return 0
  old_sha="$(metadata_value "$section" "$key" sha256)"
  tmp="$WORK_DIR/content-$(sha256sum <<<"$url" | awk '{print $1}')"
  if ! curl "${CURL_ARGS[@]}" -o "$tmp" "$url"; then
    warn "Could not refresh mutable content checksum for $id"
    return 0
  fi
  new_sha="$(sha256sum "$tmp" | awk '{print $1}')"
  add_candidate "$section" "$key" "$(package_version "$section" "$key")" \
    "sha256:$old_sha" "sha256:$new_sha" true
}

load_fixture() {
  local id latest old_integrity new_integrity force section key
  while IFS=$'\t' read -r id latest old_integrity new_integrity force; do
    [[ -n "$id" && "${id:0:1}" != '#' ]] || continue
    section="${id%%.*}"
    key="${id#*.}"
    [[ "$section" != "$key" ]] || die "invalid fixture tool id: $id"
    add_candidate "$section" "$key" "$latest" "$old_integrity" "$new_integrity" "${force:-false}"
  done <"$DOTFILES_UPGRADE_FIXTURE"
}

run_live_audit() {
  local latest
  audit_github bootstrap chezmoi twpayne/chezmoi
  audit_github core fzf junegunn/fzf
  audit_github core eza eza-community/eza
  audit_github core lazygit jesseduffield/lazygit
  audit_github core starship starship/starship
  audit_github core sops getsops/sops
  audit_github core lazydocker jesseduffield/lazydocker
  audit_github core tealdeer dbrgn/tealdeer

  if wanted languages.go; then
    latest="$(curl "${CURL_ARGS[@]}" 'https://go.dev/dl/?mode=json' 2>/dev/null | jq -r '.[0].version' | sed 's/^go//' || true)"
    add_candidate languages go "$latest"
  fi
  if wanted languages.node_lts; then
    latest="$(curl "${CURL_ARGS[@]}" https://nodejs.org/dist/index.json 2>/dev/null |
      jq -r 'map(select(.lts != false))[0].version' | sed 's/^v//' || true)"
    add_candidate languages node_lts "$latest"
  fi
  audit_npm languages typescript typescript
  audit_github languages uv astral-sh/uv
  audit_github history atuin atuinsh/atuin
  audit_github editor neovim neovim/neovim
  if wanted cloud.kubectl; then
    latest="$(curl "${CURL_ARGS[@]}" https://dl.k8s.io/release/stable.txt 2>/dev/null | sed 's/^v//' || true)"
    add_candidate cloud kubectl "$latest"
  fi
  audit_github cloud helm helm/helm
  audit_github cloud terraform hashicorp/terraform
  audit_github cloud k9s derailed/k9s
  audit_github system git_credential_manager git-ecosystem/git-credential-manager
  audit_github fonts nerd_font_version ryanoasis/nerd-fonts
  audit_npm ai_tools claude_cli @anthropic-ai/claude-code
  audit_mutable_url ai_tools codex_cli https://chatgpt.com/codex/install.sh
  audit_npm ai_tools gemini_cli @google/gemini-cli
  audit_npm ai_tools opencode opencode-ai
  audit_github ai_tools omp can1357/oh-my-pi
  audit_pypi terminal tmuxp tmuxp
  audit_github terminal herdr ogulcancelik/herdr
  audit_github media yt_dlp yt-dlp/yt-dlp
  audit_github media rmpc mierak/rmpc
}

if [[ -n "${DOTFILES_UPGRADE_FIXTURE:-}" ]]; then
  [[ -f "$DOTFILES_UPGRADE_FIXTURE" ]] || die "missing upgrade fixture: $DOTFILES_UPGRADE_FIXTURE"
  load_fixture
else
  run_live_audit
fi

format_integrity_delta() {
  local combined="$1" old new old_part new_part label
  old="${combined%% -> *}"
  new="${combined#* -> }"
  if [[ "$old" == *';'* && "$new" == *';'* ]]; then
    old_part="${old%%;*}"
    new_part="${new%%;*}"
    label="${old_part%%:*}"
    printf '<code>%s: %s -> %s</code><br>' "$label" "${old_part#*:}" "${new_part#*:}"
    old_part="${old#*;}"
    new_part="${new#*;}"
    label="${old_part%%:*}"
    printf '<code>%s: %s -> %s</code>' "$label" "${old_part#*:}" "${new_part#*:}"
  else
    printf '<code>%s -> %s</code>' "$old" "$new"
  fi
}

write_report() {
  local generated id section key current latest integrity delta count
  generated="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  count="$(wc -l <"$PLAN")"
  {
    printf '# Dotfiles Upgrade Report\n\n'
    printf 'Generated: `%s`  \n' "$generated"
    printf 'Available updates: **%s**\n\n' "$count"
    if ((count > 0)); then
      printf '| Tool | Version | Integrity | Checksum / integrity delta |\n'
      printf '| --- | --- | --- | --- |\n'
      while IFS=$'\t' read -r id section key current latest integrity delta; do
        printf '| `%s` | `%s` -> `%s` | `%s` | %s |\n' \
          "$id" "$current" "$latest" "$integrity" "$(format_integrity_delta "$delta")"
      done <"$PLAN"
      printf '\n## Accept Updates\n\n'
      printf 'Review this report, then run one of:\n\n'
      printf '```bash\n./scripts/update-packages.sh --apply-all\n'
      while IFS=$'\t' read -r id section key current latest integrity delta; do
        printf './scripts/update-packages.sh --apply %s@%s\n' "$id" "$latest"
      done <"$PLAN"
      printf '```\n\n'
      printf 'Review the resulting diff, run Docker verification, then commit and push the accepted manifest changes.\n'
    elif [[ -s "$WARNINGS" ]]; then
      printf 'No updates were fully resolved. Review the warnings before treating the repository as current.\n'
    else
      printf 'All audited versions and checksums are current.\n'
    fi
    if [[ -s "$WARNINGS" ]]; then
      printf '\n## Warnings\n\n'
      while IFS= read -r warning; do
        printf -- '- %s\n' "$warning"
      done <"$WARNINGS"
    fi
  } >"$REPORT"
}

write_report
cat "$REPORT"

apply_plan() {
  local selected="$WORK_DIR/selected.tsv" target found backup
  : >"$selected"
  if [[ "$APPLY_ALL" == true ]]; then
    cp "$PLAN" "$selected"
  else
    for target in "${TARGETS[@]}"; do
      target="${target%@*}"
      found="$(awk -F '\t' -v target="$target" '$1 == target { print; exit }' "$PLAN")"
      [[ -n "$found" ]] || die "no available, fully resolved update for $target"
      printf '%s\n' "$found" >>"$selected"
    done
  fi
  [[ -s "$selected" ]] || {
    log_skip "No package updates to apply"
    return 0
  }
  if awk -F '\t' '$7 ~ /(^| -> )(unresolved|manual-refresh-required)($| -> )/ { found = 1 } END { exit !found }' \
    "$selected"; then
    die "selected updates contain unresolved checksums"
  fi

  backup="$WORK_DIR/backup"
  mkdir -p "$backup/docs"
  cp "$PACKAGES_FILE" "$backup/packages.yaml"
  cp "$META_FILE" "$backup/packages.meta.yaml"
  cp "$EXTERNALS_FILE" "$backup/.chezmoiexternal.yaml"
  cp "$DOTFILES_SOURCE_DIR/packages.lock" "$backup/packages.lock"
  cp "$DOTFILES_SOURCE_DIR/docs/tool-inventory.md" "$backup/docs/tool-inventory.md"

  if ! python3 - "$PACKAGES_FILE" "$META_FILE" "$EXTERNALS_FILE" "$selected" <<'PYAPPLY'; then
import os
import re
import sys
import tempfile
from pathlib import Path

packages_path = Path(sys.argv[1])
meta_path = Path(sys.argv[2])
externals_path = Path(sys.argv[3])
plan_path = Path(sys.argv[4])
package_lines = packages_path.read_text(encoding="utf-8").splitlines()
meta_lines = meta_path.read_text(encoding="utf-8").splitlines()
external_lines = externals_path.read_text(encoding="utf-8").splitlines()


def set_version(lines: list[str], section: str, key: str, value: str) -> None:
    inside = False
    for index, line in enumerate(lines):
        if line == f"{section}:":
            inside = True
            continue
        if inside and line and not line.startswith((" ", "#")):
            break
        if inside and re.match(rf"  {re.escape(key)}:\s*", line):
            comment = ""
            if " #" in line:
                comment = " #" + line.split(" #", 1)[1]
            lines[index] = f'  {key}: "{value}"{comment}'
            return
    raise RuntimeError(f"manifest key not found: {section}.{key}")


def set_metadata(lines: list[str], section: str, tool: str, field: str, value: str) -> None:
    section_start = next((i for i, line in enumerate(lines) if line == f"{section}:"), None)
    if section_start is None:
        raise RuntimeError(f"metadata section not found: {section}")
    section_end = next(
        (i for i in range(section_start + 1, len(lines)) if lines[i] and not lines[i].startswith((" ", "#"))),
        len(lines),
    )
    tool_start = next(
        (i for i in range(section_start + 1, section_end) if lines[i] == f"  {tool}:"),
        None,
    )
    if tool_start is None:
        raise RuntimeError(f"metadata tool not found: {section}.{tool}")
    tool_end = next(
        (i for i in range(tool_start + 1, section_end) if re.match(r"^  \S.*:\s*$", lines[i])),
        section_end,
    )
    for index in range(tool_start + 1, tool_end):
        if re.match(rf"    {re.escape(field)}:\s*", lines[index]):
            lines[index] = f"    {field}: {value}"
            return
    lines.insert(tool_end, f"    {field}: {value}")


def set_external_fzf(lines: list[str], version: str, sha256: str) -> None:
    start = next((i for i, line in enumerate(lines) if line == '".fzf":'), None)
    if start is None:
        raise RuntimeError("external entry not found: .fzf")
    end = next((i for i in range(start + 1, len(lines)) if lines[i] and not lines[i].startswith(" ")), len(lines))
    url_found = False
    sha_found = False
    for index in range(start + 1, end):
        if re.match(r"^  url:\s*", lines[index]):
            lines[index] = f'  url: "https://github.com/junegunn/fzf/archive/v{version}.tar.gz"'
            url_found = True
        if re.match(r"^    sha256:\s*", lines[index]):
            lines[index] = f'    sha256: "{sha256}"'
            sha_found = True
    if not (url_found and sha_found):
        raise RuntimeError("external .fzf URL or SHA256 field is missing")


for raw in plan_path.read_text(encoding="utf-8").splitlines():
    tool_id, section, key, current, latest, integrity, delta = raw.split("\t", 6)
    set_version(package_lines, section, key, latest)
    if tool_id == "core.fzf":
        new_integrity = delta.split(" -> ", 1)[1]
        value = new_integrity.removeprefix("sha256:")
        if not re.fullmatch(r"[0-9a-fA-F]{64}", value):
            raise RuntimeError("invalid SHA256 for core.fzf")
        set_external_fzf(external_lines, latest, value.lower())
        continue
    if integrity != "pinned-sha256":
        continue
    new_integrity = delta.split(" -> ", 1)[1]
    values = dict(part.split(":", 1) for part in new_integrity.split(";") if ":" in part)
    if "sha256" in values:
        if not re.fullmatch(r"[0-9a-fA-F]{64}", values["sha256"]):
            raise RuntimeError(f"invalid SHA256 for {tool_id}")
        set_metadata(meta_lines, section, key, "sha256", values["sha256"].lower())
    else:
        for arch in ("amd64", "arm64"):
            value = values.get(arch, "")
            if not re.fullmatch(r"[0-9a-fA-F]{64}", value):
                raise RuntimeError(f"invalid {arch} SHA256 for {tool_id}")
            set_metadata(meta_lines, section, key, f"sha256_{arch}", value.lower())


def atomic_write(path: Path, lines: list[str]) -> None:
    handle, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write("\n".join(lines) + "\n")
        os.chmod(temporary, path.stat().st_mode)
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


atomic_write(packages_path, package_lines)
atomic_write(meta_path, meta_lines)
atomic_write(externals_path, external_lines)
PYAPPLY
    cp "$backup/packages.yaml" "$PACKAGES_FILE"
    cp "$backup/packages.meta.yaml" "$META_FILE"
    cp "$backup/.chezmoiexternal.yaml" "$EXTERNALS_FILE"
    return 1
  fi

  if ! "$DOTFILES_SOURCE_DIR/scripts/generate-package-lock.sh" ||
    ! "$DOTFILES_SOURCE_DIR/scripts/generate-tool-inventory.sh"; then
    cp "$backup/packages.yaml" "$PACKAGES_FILE"
    cp "$backup/packages.meta.yaml" "$META_FILE"
    cp "$backup/.chezmoiexternal.yaml" "$EXTERNALS_FILE"
    cp "$backup/packages.lock" "$DOTFILES_SOURCE_DIR/packages.lock"
    cp "$backup/docs/tool-inventory.md" "$DOTFILES_SOURCE_DIR/docs/tool-inventory.md"
    return 1
  fi
  log_success "Applied $(wc -l <"$selected") verified package update(s)"
}

UPDATES="$(wc -l <"$PLAN")"
if [[ "$MODE" == apply ]]; then
  apply_plan
elif [[ "$FAIL_ON_UPDATES" == true && "$UPDATES" -gt 0 ]]; then
  exit 3
fi
