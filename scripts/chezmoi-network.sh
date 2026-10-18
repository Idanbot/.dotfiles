#!/usr/bin/env bash
# Retry transient external-download failures without returning partial status.

chezmoi_with_retry() (
  local attempts="${DOTFILES_CHEZMOI_ATTEMPTS:-4}" delay="${DOTFILES_CHEZMOI_RETRY_DELAY:-10}"
  local attempt status temporary
  [[ "$attempts" =~ ^[1-9][0-9]*$ && "$delay" =~ ^[0-9]+$ ]] || return 2
  temporary="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$temporary"' EXIT
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if chezmoi "$@" >"$temporary/stdout" 2>"$temporary/stderr"; then
      cat "$temporary/stdout"
      cat "$temporary/stderr" >&2
      return 0
    else
      status=$?
    fi
    cat "$temporary/stderr" >&2
    if ((attempt == attempts)) ||
      ! grep -Eiq '(https?://|download|fetch).*(429|Too Many Requests|50[0-9]|timeout|timed out|connection reset|unexpected EOF|temporary failure)|dial tcp.*(timeout|temporary failure)|TLS handshake timeout' \
        "$temporary/stderr"; then
      return "$status"
    fi
    printf 'Chezmoi external download temporarily unavailable (attempt %s/%s); retrying in %ss\n' \
      "$attempt" "$attempts" "$delay" >&2
    sleep "$delay"
  done
)
