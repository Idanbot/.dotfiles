#!/usr/bin/env bash
# Internal logging helpers; source scripts/lib.sh as the public entry point.

if terminal_supports_color; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
  BOLD=""
  DIM=""
  NC=""
fi

_INSTALLED=0
_UPGRADED=0
_PRESERVED=0
_SKIPPED=0
_FAILED=0
_WARNINGS=0

timestamp() { date '+%H:%M:%S'; }

json_escape() {
  local value="${1:-}"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\b'/\\b}
  value=${value//$'\f'/\\f}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  value=${value//$'\v'/\\u000b}
  value=${value//$'\a'/\\u0007}
  printf '%s' "$value"
}

emit_event() {
  local level="$1"
  shift
  [[ -n "${DOTFILES_EVENT_LOG:-}" ]] || return 0
  umask 077
  mkdir -p "$(dirname "$DOTFILES_EVENT_LOG")"
  printf '{"time":"%s","run_id":"%s","section":"%s","level":"%s","message":"%s"}\n' \
    "$(json_escape "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")" \
    "$(json_escape "${DOTFILES_RUN_ID:-unknown}")" \
    "$(json_escape "${DOTFILES_SECTION:-bootstrap}")" \
    "$(json_escape "$level")" \
    "$(json_escape "$*")" >>"$DOTFILES_EVENT_LOG"
  chmod 600 "$DOTFILES_EVENT_LOG"
}

log_line() {
  local level="$1" color="$2" spacing="$3"
  shift 3
  printf '%s %b[%s]%b%s%s\n' "$(timestamp)" "$color" "$level" "$NC" "$spacing" "$*"
  emit_event "${level,,}" "$*"
}

log_info() { log_line INFO "$BLUE" "  " "$*"; }
log_success() {
  log_line OK "$GREEN" "    " "$*"
}
log_warn() {
  log_line WARN "$YELLOW" "  " "$*"
  ((_WARNINGS++)) || true
}
log_error() {
  log_line ERROR "$RED" " " "$*" >&2
  ((_FAILED++)) || true
}
log_skip() {
  log_line SKIP "$DIM" "  " "$*"
  ((_SKIPPED++)) || true
}
log_step() {
  printf '\n%b== %s ==%b\n' "$BOLD$CYAN" "$*" "$NC"
  emit_event step "$*"
}

redact_manager_output() {
  sed -E -e $'s/\033\\[[0-9;]*[[:alpha:]]//g' \
    -e 's/((token|password|secret|api[_-]?key)[=:][[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig'
}

# Keep native progress noise in the existing run log, not the full-install console.
run_manager() (
  # The caller holds the lock; native children must not retain its descriptor.
  [[ -z "${MANAGED_OPERATION_FD:-}" ]] || exec {MANAGED_OPERATION_FD}>&-
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  if [[ -z "${DOTFILES_MANAGER_LOG:-}" || "${DOTFILES_VERBOSE:-0}" == 1 ]]; then
    "$@"
    return
  fi
  local output
  [[ -f "$DOTFILES_MANAGER_LOG" && ! -L "$DOTFILES_MANAGER_LOG" ]] || {
    log_error "Native manager output requires an existing regular run log"
    return 1
  }
  output="$(mktemp)" || return 1
  finish_manager_output() {
    local status="$?"
    trap '' HUP INT TERM
    redact_manager_output <"$output" >>"$DOTFILES_MANAGER_LOG" || status=1
    if [[ "$status" == 0 ]]; then
      redact_manager_output <"$output" | grep -Ei '(^|[[:space:]])(warning|warn|error)(:|[[:space:]])' || true
    else
      redact_manager_output <"$output" | tail -n 15 >&2
    fi
    rm -f -- "$output" || status=1
    exit "$status"
  }
  trap finish_manager_output EXIT
  "$@" >"$output" 2>&1
)

print_summary() {
  local name="${1:-$(basename "$0")}" total
  total=$((_INSTALLED + _UPGRADED + _SKIPPED + _PRESERVED + _FAILED))
  printf '\n%b-- Summary: %s --%b\n' "$BOLD" "$name" "$NC"
  printf '  %bInstalled:%b %s  %bUpgraded:%b %s  %bSkipped:%b %s  Preserved: %s  %bWarnings:%b %s  %bFailed:%b %s  Total: %s\n' \
    "$GREEN" "$NC" "$_INSTALLED" "$GREEN" "$NC" "$_UPGRADED" "$DIM" "$NC" "$_SKIPPED" \
    "$_PRESERVED" "$YELLOW" "$NC" "$_WARNINGS" "$RED" "$NC" "$_FAILED" "$total"
  emit_event summary "installed=$_INSTALLED upgraded=$_UPGRADED skipped=$_SKIPPED preserved=$_PRESERVED warnings=$_WARNINGS failed=$_FAILED"
  [[ $_FAILED -eq 0 ]]
}
