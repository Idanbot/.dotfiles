#!/usr/bin/env bash
# Extended fzf image/dir/pdf preview
# - Directories: ll listing (eza or ls -la --color)
# - PDFs: pdftoppm (first page) -> kitty icat (or chafa fallback)
# - Images: same as official script (kitty/chafa/imgcat)

if [[ $# -ne 1 ]]; then
  >&2 echo "usage: $0 FILENAME[:LINENO][:IGNORED]"
  exit 1
fi

# Expand ~
file=${1/#\~\//$HOME/}

# Optional center line
center=0
if [[ ! -r $file ]]; then
  if [[ $file =~ ^(.+):([0-9]+)\ *$ ]] && [[ -r ${BASH_REMATCH[1]} ]]; then
    file=${BASH_REMATCH[1]}
    center=${BASH_REMATCH[2]}
  elif [[ $file =~ ^(.+):([0-9]+):[0-9]+\ *$ ]] && [[ -r ${BASH_REMATCH[1]} ]]; then
    file=${BASH_REMATCH[1]}
    center=${BASH_REMATCH[2]}
  fi
fi

# If it's a directory: "ll" view
if [[ -d $file ]]; then
  if command -v eza >/dev/null 2>&1; then
    eza -la --group-directories-first --icons=always --color=always -- "$file"
  else
    ls -la --color=always --group-directories-first -- "$file"
  fi
  exit
fi

# MIME type
type=$(file --brief --dereference --mime -- "$file")

# Geometry of the preview pane
dim=${FZF_PREVIEW_COLUMNS}x${FZF_PREVIEW_LINES}
if [[ $dim = x ]]; then
  dim=$(stty size </dev/tty | awk '{print $2 "x" $1}')
elif ! [[ $KITTY_WINDOW_ID ]] && ((FZF_PREVIEW_TOP + FZF_PREVIEW_LINES == $(stty size </dev/tty | awk '{print $1}'))); then
  dim=${FZF_PREVIEW_COLUMNS}x$((FZF_PREVIEW_LINES - 1))
fi

# ----- PDF branch -----
if [[ $type == application/pdf* ]]; then
  prefix="$(mktemp -u /tmp/fzfpdf.XXXXXX)"
  if command -v pdftoppm >/dev/null 2>&1; then
    pdftoppm -f 1 -l 1 -png -- "$file" "$prefix" >/dev/null 2>&1 || {
      echo "pdftoppm failed"
      exit
    }
    png="${prefix}-1.png"
    if [[ -f $png ]]; then
      if { [[ $KITTY_WINDOW_ID ]] || [[ $GHOSTTY_RESOURCES_DIR ]]; } &&
        command -v kitten >/dev/null 2>&1; then
        kitten icat --clear --transfer-mode=memory --unicode-placeholder --stdin=no --place="$dim@0x0" "$png" |
          sed '\$d' | sed $'\$s/$/\\e[m/'
      elif command -v chafa >/dev/null 2>&1; then
        chafa -s "$dim" "$png"
        echo
      elif command -v imgcat >/dev/null 2>&1; then
        imgcat -W "${dim%%x*}" -H "${dim##*x}" "$png"
      else
        file "$file"
      fi
      rm -f "$png"
      exit
    fi
  fi
fi

# ----- Non-image fallback -----
if [[ ! $type =~ ^image/ ]]; then
  if [[ $type =~ =binary ]]; then
    file -- "$1"
    exit
  fi
  if command -v batcat >/dev/null; then
    batname="batcat"
  elif command -v bat >/dev/null; then
    batname="bat"
  else
    cat -- "$1"
    exit
  fi
  ${batname} --style="${BAT_STYLE:-numbers}" --color=always --pager=never \
    --highlight-line="${center:-0}" -- "$file"
  exit
fi

# ----- Images -----
if { [[ $KITTY_WINDOW_ID ]] || [[ $GHOSTTY_RESOURCES_DIR ]]; } && command -v kitten >/dev/null; then
  kitten icat --clear --transfer-mode=memory --unicode-placeholder --stdin=no --place="$dim@0x0" "$file" |
    sed '\$d' | sed $'\$s/$/\\e[m/'
elif command -v chafa >/dev/null; then
  chafa -s "$dim" "$file"
  echo
elif command -v imgcat >/dev/null; then
  imgcat -W "${dim%%x*}" -H "${dim##*x}" "$file"
else
  file -- "$file"
fi
