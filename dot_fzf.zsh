# The executable is installed separately with release checksum verification.
if command -v fzf >/dev/null 2>&1; then
  source <(fzf --zsh)
fi
