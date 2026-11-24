#!/usr/bin/env bash
# Coordinate an external edit after authorization without relying on sleep timing.
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

for scenario in binary tree appeared takeover replaced parent app link file; do
  (
    export HOME="$temporary/$scenario" DOTFILES_SOURCE_DIR="$ROOT"
    export DOTFILES_STATE_DIR="$HOME/state"
    mkdir -p "$HOME/.local/bin" "$HOME/source/bin"
    source "$ROOT/scripts/lib.sh"
    target="$HOME/.local/bin/fixture"
    case "$scenario" in tree | app) target="$HOME/.local/app" ;; esac
    printf '#!/bin/sh\nexit 0\n' >"$HOME/old"
    cat >"$HOME/new" <<'EOF'
#!/bin/sh
touch "$HOME/ready"
for attempt in $(seq 100); do
  [ ! -e "$HOME/release" ] || exit 0
  sleep .02
done
exit 1
EOF
    chmod 755 "$HOME/old" "$HOME/new"
    app_probe() { bounded_probe "$1/bin/fixture"; }
    invoke() {
      case "$scenario" in
        tree | app)
          cp "$HOME/$1" "$HOME/source/bin/fixture"
          if [[ "$scenario" == tree ]]; then
            install_managed_tree "$HOME/source" "$target" fixture "$2" test bin/fixture
          else
            install_managed_app "$HOME/source" "$target" fixture "$2" test app_probe fixture
          fi
          ;;
        link) managed_link "$HOME/$1" "$target" fixture "$2" ;;
        file) install_managed_file "$HOME/$1" "$target" fixture "$2" test ;;
        *) install_managed_binary "$HOME/$1" fixture "$2" test 'fixture --version' ;;
      esac
    }
    case "$scenario" in
      appeared) ;;
      takeover)
        cp "$HOME/old" "$target"
        export DOTFILES_REPLACE_BINARIES=fixture
        ;;
      *) invoke old 1 ;;
    esac
    if [[ "$scenario" == link || "$scenario" == file ]]; then
      eval "$(declare -f snapshot_publication | sed '1s/snapshot_publication/original_snapshot/')"
      snapshot_publication() {
        original_snapshot "$@" && "$HOME/new"
      }
    fi
    record_install unrelated 1 apt fixture-unrelated
    metadata() (
      cd "$DOTFILES_STATE_DIR"
      find . -type f \( -name installed.tsv -o -path './ownership/*' \) -print0 |
        sort -z | xargs -0 sha256sum
    )
    before="$(metadata)"
    invoke new 2 >"$HOME/output" 2>&1 &
    installer=$!
    for _ in {1..100}; do
      [[ ! -e "$HOME/ready" ]] || break
      kill -0 "$installer" 2>/dev/null || break
      sleep .02
    done
    [[ -e "$HOME/ready" ]] || {
      cat "$HOME/output"
      exit 1
    }
    case "$scenario" in
      tree) touch "$target/local-file" ;;
      app | link)
        ln -sfn "$HOME/local-link" "$HOME/.local/bin/fixture"
        ;;
      parent)
        mv "$HOME/.local/bin" "$HOME/.local/original"
        mkdir "$HOME/replacement"
        ln -s "$HOME/replacement" "$HOME/.local/bin"
        printf 'external\n' >"$target"
        ;;
      replaced)
        cp -p "$target" "$HOME/replacement"
        mv "$HOME/replacement" "$target"
        ;;
      *) printf 'local edit\n' >>"$target" ;;
    esac
    edited="$(managed_target_digest "$target")"
    inode="$(stat -c '%i' "$target")"
    touch "$HOME/release"
    if wait "$installer"; then
      printf 'Publication accepted drift: %s\n' "$scenario" >&2
      exit 1
    fi
    [[ "$(managed_target_digest "$target")" == "$edited" ]]
    [[ "$(stat -c '%i' "$target")" == "$inode" ]]
    [[ "$(metadata)" == "$before" ]]
    grep -Fq 'changed before publication' "$HOME/output"
    if [[ "$scenario" == parent ]]; then
      compgen -G "$HOME/.local/original/.dotfiles-binary.*" >/dev/null
    else
      [[ -z "$(find "$(dirname "$target")" -maxdepth 1 -type d -name '.dotfiles-*' -print)" ]]
    fi
    if [[ "$scenario" == app ]]; then
      [[ "$(readlink "$HOME/.local/bin/fixture")" == "$HOME/local-link" ]]
    fi
    if [[ "$scenario" == takeover ]]; then
      [[ ! -e "$DOTFILES_STATE_DIR/binary-backups" ]]
    fi
    printf 'Destination drift preserved: %s\n' "$scenario"
  )
done
