# The executable is installed separately with release checksum verification.
() {
  local executable=${commands[fzf]} integration
  local distro_scripts=/usr/share/doc/fzf/examples
  [[ -n "$executable" ]] || return 0
  (( ! $+widgets[fzf-history-widget] )) || return 0

  if integration=$(command fzf --zsh 2>/dev/null) && [[ -n "$integration" ]]; then
    eval "$integration"
  elif [[ "${executable:A}" == /usr/bin/fzf &&
    -r "$distro_scripts/completion.zsh" && -r "$distro_scripts/key-bindings.zsh" ]]; then
    source "$distro_scripts/completion.zsh"
    source "$distro_scripts/key-bindings.zsh"
  fi
  # Keep startup usable; doctor reports a missing widget separately.
  return 0
}
