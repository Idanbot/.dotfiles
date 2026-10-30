#!/usr/bin/env bash
# Remove only paths recorded in the managed-install ledger.

set -euo pipefail
DOTFILES_SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"

INCLUDE_PACKAGES=false
DRY_RUN=false
TOOL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-packages)
      INCLUDE_PACKAGES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h | --help)
      printf 'Usage: scripts/uninstall-tool.sh [--dry-run] [--include-packages] <tool>\n'
      exit 0
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      TOOL="$1"
      shift
      ;;
  esac
done
[[ -n "$TOOL" ]] || {
  printf 'A tool name is required\n' >&2
  exit 2
}

STATE_ROOT="${DOTFILES_STATE_DIR:-$HOME/.local/state/dotfiles}"
managed_operation_lock
LEDGER="$STATE_ROOT/installed.tsv"
[[ -f "$LEDGER" ]] || {
  printf 'No managed-install ledger exists\n' >&2
  exit 1
}

safe_target() {
  local target="$1" parent
  [[ "$target" == "$HOME/.local/"* || "$target" == "$HOME/.cargo/"* || "$target" == /usr/local/* ]] || return 1
  parent="$(realpath -m -- "$(dirname "$target")")" || return 1
  [[ "$parent" == "$(dirname "$target")" ]] || return 1
}

matches="$(awk -F '\t' -v tool="$TOOL" '$1 == tool' "$LEDGER")"
[[ -n "$matches" ]] || {
  printf '%s is not recorded as managed\n' "$TOOL"
  exit 0
}

# Authorize the complete plan before deleting even a shim or a ledger entry.
declare -A groups=() packages=() roots=() bins=() payloads=() bindings=()
while IFS=$'\t' read -r tool _version owner target _section _installed_at; do
  kind="" package=""
  case "$owner" in
    npm:*)
      kind=npm
      package="${owner#npm:}"
      ;;
    uv:*)
      kind=uv
      package="${owner#uv:}"
      ;;
    uv-python)
      kind=python
      package="${target##*/}"
      ;;
    uv)
      kind=uv
      package="$tool"
      [[ "$tool" != python ]] || {
        kind=python
        package="${target##*/}"
      }
      ;;
    omp:*)
      kind=omp
      package="${owner#omp:}"
      ;;
    uvx | apt | dpkg) continue ;;
    agent-skill:*) [[ "$target" == "$HOME/.agents/skills/$tool" ]] && assert_owned_target "$target" || exit 1 ;;
    *) safe_target "$target" && assert_owned_target "$target" || exit 1 ;;
  esac
  [[ -n "$kind" ]] || continue
  if [[ -z "${groups[$owner]:-}" ]]; then
    manager_scope "$kind" "$package" "$tool" && manager_assert_owned "$owner" || {
      printf 'Refusing uninstall: %s package scope or ownership is unverifiable\n' "$tool" >&2
      exit 1
    }
    [[ -d "$MANAGER_TARGET" ]] || {
      printf 'Package payload is absent: %s\n' "$tool" >&2
      exit 1
    }
    groups[$owner]="$kind" packages[$owner]="$package"
    roots[$owner]="$MANAGER_ROOT" bins[$owner]="$MANAGER_BINS"
    payloads[$owner]="$MANAGER_TARGET"
    bindings[$owner]="$(printf '%s\n' "${MANAGER_PATHS[@]}")"
  fi
  grep -Fxq -- "$target" <<<"${bindings[$owner]}" || {
    printf 'Refusing ledger destination outside the native package scope\n' >&2
    exit 1
  }
done <<<"$matches"

# A manager owns the package as a unit, even when the ledger lists many commands.
for owner in "${!groups[@]}"; do
  kind="${groups[$owner]}" package="${packages[$owner]}"
  if [[ "$DRY_RUN" == true ]]; then
    case "$kind" in
      npm) printf 'would npm uninstall %s\n' "$package" ;;
      uv) printf 'would uv tool uninstall %s\n' "$package" ;;
      python) printf 'would uv python uninstall %s\n' "$package" ;;
      omp) printf 'would omp plugin uninstall %s\n' "$package" ;;
    esac
    continue
  fi
  case "$kind" in
    npm) run_manager npm uninstall --global --prefix "${roots[$owner]}" --no-audit --no-fund "$package" ;;
    uv) UV_TOOL_DIR="${roots[$owner]}" UV_TOOL_BIN_DIR="${bins[$owner]}" run_manager uv tool uninstall "$package" ;;
    python) UV_PYTHON_INSTALL_DIR="${roots[$owner]}" run_manager uv python uninstall "$package" ;;
    omp) run_manager omp plugin uninstall "$package" ;;
  esac
  if [[ -e "${payloads[$owner]}" || -L "${payloads[$owner]}" ]]; then
    printf 'Manager left the package installed; receipts preserved for %s\n' "$tool" >&2
    exit 1
  fi
  while IFS= read -r target; do
    # Native managers normally remove these links; clean only verified leftovers.
    [[ ! -L "$target" || -e "$target" ]] || rm -f -- "$target"
  done <<<"${bindings[$owner]}"
done

while IFS=$'\t' read -r tool _version owner target _section _installed_at; do
  case "$owner" in
    uvx)
      printf 'preserved shared UV cache for %s; removing only its ledger entry\n' "$tool"
      ;;
    apt)
      if [[ "$INCLUDE_PACKAGES" == true ]]; then
        [[ "$DRY_RUN" == true ]] && printf 'would apt remove %s\n' "$target" || sudo apt-get remove -y "$target"
      else
        printf 'preserved apt package %s (use --include-packages to remove)\n' "$target"
        continue
      fi
      ;;
    npm:* | uv-python | uv | uv:* | omp:*) ;;
    agent-skill:*)
      [[ "$target" == "$HOME/.agents/skills/$tool" ]] || {
        printf 'Refusing unsafe agent skill path: %s\n' "$target" >&2
        exit 1
      }
      assert_owned_target "$target"
      [[ "$DRY_RUN" == true ]] && printf 'would remove %s\n' "$target" || rm -rf -- "$target"
      ;;
    dpkg)
      if [[ "$INCLUDE_PACKAGES" == true ]]; then
        [[ "$DRY_RUN" == true ]] && printf 'would apt remove %s\n' "$target" || sudo apt-get remove -y "$target"
      else
        printf 'preserved dpkg package %s (use --include-packages to remove)\n' "$target"
        continue
      fi
      ;;
    *)
      safe_target "$target" || {
        printf 'Refusing unsafe ledger path: %s\n' "$target" >&2
        exit 1
      }
      assert_owned_target "$target"
      if [[ "$DRY_RUN" == true ]]; then
        printf 'would remove %s\n' "$target"
      else
        rm -rf -- "$target"
        printf 'removed %s\n' "$target"
      fi
      ;;
  esac
  if [[ "$DRY_RUN" == false ]]; then
    forget_install "$tool" "$target"
  fi
done <<<"$matches"
