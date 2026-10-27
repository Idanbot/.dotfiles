#!/usr/bin/env bash
# Inject failures after publication, including metadata writes and rollback.
set -euo pipefail
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TEMPORARY="$(mktemp -d)"
trap 'rm -rf "$TEMPORARY"' EXIT

for kind in binary tree link; do
  for failure in publication ledger rollback metadata-rollback snapshot stamp fresh-ledger unchanged-ledger INT TERM HUP; do
    (
      export HOME="$TEMPORARY/$kind-$failure" DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
      export DOTFILES_STATE_DIR="$HOME/state"
      mkdir -p "$HOME/.local/bin" "$HOME/source/bin"
      source "$DOTFILES_DIR/scripts/lib.sh"
      printf '#!/bin/sh\nprintf "old\\n"\n' >"$HOME/old"
      printf '#!/bin/sh\nprintf "new\\n"\n' >"$HOME/new"
      chmod 755 "$HOME/old" "$HOME/new"
      target="$HOME/.local/bin/fixture"
      invoke() {
        case "$kind" in
          binary) install_managed_binary "$HOME/$1" fixture "$2" test 'fixture --version' ;;
          tree)
            install -m 755 "$HOME/$1" "$HOME/source/bin/fixture"
            install_managed_tree "$HOME/source" "$target" fixture "$2" test bin/fixture
            ;;
          link) managed_link "$HOME/$1" "$target" fixture "$2" ;;
        esac
      }
      [[ "$kind" != tree ]] || target="$HOME/.local/tree"
      publication_destination="$target"
      [[ "$failure" == fresh-ledger ]] || invoke old 1
      record_install unrelated 1 apt unrelated-package
      before="$(managed_target_digest "$target")"
      stamp="$(ownership_stamp "$target")"
      [[ ! -f "$stamp" ]] || cp "$stamp" "$HOME/stamp-before"
      awk -F '\t' -v path="$target" '$4 == path' "$DOTFILES_STATE_DIR/installed.tsv" >"$HOME/records-before"
      eval "$(declare -f record_install | sed '1s/record_install/original_record_install/')"
      record_install() {
        original_record_install "$@" || return 1
        original_record_install unrelated 2 apt unrelated-package || return 1
        case "$failure" in
          ledger | rollback | metadata-rollback | fresh-ledger | unchanged-ledger) return 9 ;;
          INT | TERM | HUP) kill -s "$failure" "$BASHPID" ;;
        esac
      }
      mv() {
        if [[ "$failure" == publication && "${!#}" == "$publication_destination" ]]; then return 8; fi
        if [[ "$failure" == metadata-rollback && "$*" == *'/ledger-restore '* ]]; then return 8; fi
        if [[ "$failure" == stamp && "${!#}" == "$stamp" && "$*" != *'/stamp-restore '* ]]; then return 8; fi
        command mv "$@"
      }
      cp() {
        if [[ "$failure" == rollback && "$*" == *'/previous '* ]]; then return 7; fi
        if [[ "$failure" == snapshot && "${!#}" == */previous ]]; then return 7; fi
        command cp "$@"
      }
      candidate=new
      [[ "$failure" != unchanged-ledger ]] || candidate=old
      status=0
      invoke "$candidate" 2 >"$HOME/output" 2>&1 || status=$?
      if [[ "$status" == 0 ]]; then
        printf 'Publication unexpectedly accepted %s/%s\n' "$kind" "$failure" >&2
        exit 1
      fi
      case "$failure" in
        INT) [[ "$status" == 130 ]] ;;
        TERM) [[ "$status" == 143 ]] ;;
        HUP) [[ "$status" == 129 ]] ;;
      esac
      if [[ "$failure" == rollback || "$failure" == metadata-rollback ]]; then
        recovery="$(find "$(dirname "$target")" -maxdepth 1 -type d -name '.dotfiles-*' -print)"
        [[ -n "$recovery" && "$(stat -c '%a' "$recovery")" == 700 ]]
        [[ "$(managed_target_digest "$recovery/previous")" == "$before" ]]
        grep -q 'Recovery files retained' "$HOME/output"
      else
        [[ "$(managed_target_digest "$target")" == "$before" ]]
        if [[ -f "$HOME/stamp-before" ]]; then
          cmp "$stamp" "$HOME/stamp-before"
        else
          [[ ! -e "$stamp" ]]
        fi
        awk -F '\t' -v path="$target" '$4 == path' "$DOTFILES_STATE_DIR/installed.tsv" >"$HOME/records-after"
        cmp "$HOME/records-before" "$HOME/records-after"
        [[ "$failure" == fresh-ledger ]] || target_is_owned "$target"
        [[ -z "$(find "$(dirname "$target")" -maxdepth 1 -type d -name '.dotfiles-*' -print)" ]]
      fi
      if [[ "$failure" != publication && "$failure" != snapshot && "$failure" != stamp ]]; then
        grep -q $'unrelated\t2\t' "$DOTFILES_STATE_DIR/installed.tsv"
      fi
      printf 'Publication recovery passed: %s/%s\n' "$kind" "$failure"
    )
  done
done
