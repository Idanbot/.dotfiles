# ytplay — Stream a YouTube video with mpv
ytplay() {
  if [[ -z "$1" ]]; then
    echo "Usage: ytplay <url>"
    return 1
  fi
  mpv "$1"
}
