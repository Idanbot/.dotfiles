#!/usr/bin/env bash
# Execute installer call sites, not just ownership predicates, with offline tools.
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
export DOTFILES_SOURCE_DIR="$ROOT"
for tool in kubectl graphify yt-dlp git-credential-manager; do
  case "$tool" in
    kubectl) section=05-install-containers-cloud start=KUBECTL_VERSION= end=HELM_VERSION= ;;
    graphify) section=08-install-ai-tools start=GRAPHIFY_VERSION= end=RTK_VERSION= ;;
    yt-dlp) section=09-install-media-tools start=YTDLP_VERSION= end=require_sudo ;;
    git-credential-manager) section=12-configure-system start=GCM_VERSION= end='if is_native' ;;
  esac
  awk -v start="$start" -v end="$end" '
    index($0, start) == 1 { block = 1 }
    index($0, end) == 1 { exit }
    block
  ' "$ROOT/.chezmoiscripts/run_once_$section.sh.tmpl" >"$temporary/$tool.sh"
  for scenario in external modified unverifiable managed-unverifiable distro; do
    [[ "$scenario" != distro || "$tool" == git-credential-manager ]] || continue
    (
      export HOME="$temporary/$tool-$scenario" DOTFILES_SECTION=test
      export DOTFILES_STATE_DIR="$HOME/state" DOTFILES_VERSION_PLAN="$HOME/versions.json"
      mkdir -p "$HOME/.local/bin" "$HOME/external/bin"
      printf '{"tools":{}}\n' >"$DOTFILES_VERSION_PLAN"
      source "$ROOT/scripts/lib.sh"
      RELEASE_ARCH="$(get_arch)"
      export RELEASE_ARCH
      [[ ! -f "$ROOT/scripts/install-uv-tool.sh" ]] || source "$ROOT/scripts/install-uv-tool.sh"
      target="$HOME/external/bin/$tool"
      if [[ "$scenario" == modified || "$scenario" == managed-unverifiable ]]; then
        target="$HOME/.local/bin/$tool"
      fi
      printf '#!/bin/sh\necho 0.0.1\n' >"$target"
      chmod +x "$target"
      if [[ "$scenario" == modified || "$scenario" == managed-unverifiable ]]; then
        record_install "$tool" 0.0.1 fixture "$target"
      fi
      if [[ "$scenario" == modified ]]; then
        printf '# locally modified\n' >>"$target"
      elif [[ "$scenario" == unverifiable || "$scenario" == managed-unverifiable ]]; then
        printf '#!/bin/sh\nexit 37\n' >"$target"
        # Keep the managed unknown-version binary owned, unlike the modified case.
        if [[ "$scenario" == managed-unverifiable ]]; then
          record_install "$tool" unknown fixture "$target"
        fi
      fi
      export PATH="$HOME/.local/bin:$HOME/external/bin:$PATH"
      if [[ "$scenario" == distro ]]; then
        export DOTFILES_REPLACE_BINARIES=git-credential-manager
        dpkg-query() { printf 'gcm: %s\n' "$2"; }
      fi
      download_verified() {
        printf 'unexpected download for %s/%s\n' "$tool" "$scenario" >&2
        return 99
      }
      install_managed_binary() {
        printf 'unexpected binary replacement\n' >&2
        return 99
      }
      uv() {
        case "$*" in
          'tool dir')
            printf '%s\n' "$HOME/.local/share/uv/tools"
            return
            ;;
          'tool dir --bin')
            printf '%s\n' "$HOME/.local/bin"
            return
            ;;
        esac
        printf 'unexpected uv mutation: %s\n' "$*" >&2
        return 99
      }
      before="$(managed_target_digest "$target")"
      ledger_before="$(managed_target_digest "$DOTFILES_STATE_DIR/installed.tsv")"
      source "$temporary/$tool.sh"
      source "$temporary/$tool.sh"
      [[ "$(managed_target_digest "$target")" == "$before" ]]
      [[ "$(managed_target_digest "$DOTFILES_STATE_DIR/installed.tsv")" == "$ledger_before" ]]
      [[ "$(command -v "$tool")" == "$target" ]]
      [[ "$target" == "$HOME/.local/bin/$tool" || ! -e "$HOME/.local/bin/$tool" ]]
    )
  done
done

# The shared decision can veto mutation even when live ownership allows it.
for binary in git-credential-manager nvim; do
  (
    export HOME="$temporary/decision-$binary" DOTFILES_STATE_DIR="$temporary/decision-$binary-state"
    export DOTFILES_VERSION_PLAN="$temporary/decision-$binary.json"
    mkdir -p "$HOME/.local/bin"
    export PATH="$HOME/.local/bin:$PATH"
    source "$ROOT/scripts/lib.sh"
    printf '#!/bin/sh\necho 0.0.1\n' >"$HOME/.local/bin/$binary"
    chmod +x "$HOME/.local/bin/$binary"
    record_install "$binary" 0.0.1 fixture "$HOME/.local/bin/$binary"
    id=editor.neovim
    [[ "$binary" != git-credential-manager ]] || id=system.git_credential_manager
    jq -n --arg id "$id" --arg path "$HOME/.local/bin/$binary" \
      '{schema:1,tools:{($id):{decision:{schema:1,operation:"preserve",target:"99.0.0",evidence:{path:$path}}}}}' >"$DOTFILES_VERSION_PLAN"
    before="$(managed_target_digest "$DOTFILES_STATE_DIR/installed.tsv")"
    runtime_is_current "$binary" 99.0.0 0.0.1
    # Stale target/path inputs also fail closed rather than broadening approval.
    runtime_is_current "$binary" 100.0.0 0.0.1
    jq --arg id "$id" '.tools[$id].decision.evidence.path = "/changed/fixture"' \
      "$DOTFILES_VERSION_PLAN" >"$DOTFILES_VERSION_PLAN.tmp"
    mv "$DOTFILES_VERSION_PLAN.tmp" "$DOTFILES_VERSION_PLAN"
    runtime_is_current "$binary" 99.0.0 0.0.1
    [[ "$(managed_target_digest "$DOTFILES_STATE_DIR/installed.tsv")" == "$before" ]]
  )
done

# A command introduced after the initial decision must not be shadowed at commit.
(
  export HOME="$temporary/kubectl-race" DOTFILES_STATE_DIR="$temporary/kubectl-race-state"
  export DOTFILES_VERSION_PLAN="$temporary/kubectl-race-versions.json"
  printf '{"tools":{}}\n' >"$DOTFILES_VERSION_PLAN"
  mkdir -p "$HOME/.local/bin" "$HOME/external/bin"
  source "$ROOT/scripts/lib.sh"
  export PATH="$HOME/.local/bin:$HOME/external/bin:$PATH"
  RELEASE_ARCH="$(get_arch)"
  export RELEASE_ARCH
  download_verified() {
    printf '#!/bin/sh\necho 0.0.1\n' >"$HOME/external/bin/kubectl"
    chmod +x "$HOME/external/bin/kubectl"
    cp "$HOME/external/bin/kubectl" "$2"
  }
  install_managed_binary() {
    printf 'kubectl shadowed a late external command\n' >&2
    return 99
  }
  source "$temporary/kubectl.sh"
  [[ "$(command -v kubectl)" == "$HOME/external/bin/kubectl" ]]
  [[ ! -e "$HOME/.local/bin/kubectl" && ! -e "$DOTFILES_STATE_DIR/installed.tsv" ]]
)
printf 'Actual-section external, modified, and unverifiable preservation passed\n'
