# mkcd — Create a directory and cd into it
mkcd() {
  mkdir -p "$1" && cd "$1" || return 1
}
