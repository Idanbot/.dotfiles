#!/usr/bin/env bash
# Transactional backup and restore for paths changed by chezmoi.

set -euo pipefail

STATE_ROOT="${DOTFILES_STATE_DIR:-$HOME/.local/state/dotfiles}"
BACKUP_ROOT="$STATE_ROOT/backups"

usage() {
  cat <<'USAGE'
Usage:
  scripts/backup.sh create --status-file <file> [--run-id <id>]
  scripts/backup.sh list
  scripts/backup.sh verify <backup-id|latest>
  scripts/backup.sh restore <backup-id|latest> [--force]
  scripts/backup.sh prune [count]

Backups contain a manifest for both existing and previously absent paths. Restore
therefore removes files created by a failed apply and restores replaced content.
USAGE
}

safe_relative_path() {
  local path="$1"
  [[ -n "$path" && "$path" != /* && "$path" != .. && "$path" != ../* ]] || return 1
  [[ "$path" != */../* && "$path" != */.. ]] || return 1
  [[ "$path" != . && "$path" != ./* && "$path" != */./* && "$path" != */. ]]
}

status_path() {
  local line="$1" path
  path="${line:3}"
  path="${path#"${path%%[![:space:]]*}"}"
  printf '%s\n' "$path"
}

create_backup() {
  local status_file="" run_id="manual" id dir manifest line rel target type mode hash
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status-file)
        status_file="${2:-}"
        shift 2
        ;;
      --run-id)
        run_id="${2:-}"
        shift 2
        ;;
      *)
        printf 'Unknown create option: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done
  [[ -f "$status_file" ]] || {
    printf 'Missing status file: %s\n' "$status_file" >&2
    exit 2
  }

  umask 077
  id="$(date -u '+%Y%m%dT%H%M%SZ')-${run_id//[^a-zA-Z0-9._-]/_}"
  dir="$BACKUP_ROOT/$id"
  manifest="$dir/manifest.tsv"
  mkdir -p "$dir/files"
  chmod 700 "$STATE_ROOT" "$BACKUP_ROOT" "$dir" "$dir/files"
  printf 'path\ttype\tmode\tsha256\n' >"$manifest"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    rel="$(status_path "$line")"
    safe_relative_path "$rel" || {
      printf 'Unsafe path in chezmoi status: %s\n' "$rel" >&2
      exit 1
    }
    target="$HOME/$rel"
    if [[ -L "$target" ]]; then
      type=symlink
      mode='-'
      hash="$(readlink "$target" | sha256sum | awk '{print $1}')"
      mkdir -p "$dir/files/$(dirname "$rel")"
      cp -a "$target" "$dir/files/$rel"
    elif [[ -f "$target" ]]; then
      type="file"
      mode="$(stat -c '%a' "$target")"
      hash="$(sha256sum "$target" | awk '{print $1}')"
      mkdir -p "$dir/files/$(dirname "$rel")"
      cp -a "$target" "$dir/files/$rel"
    elif [[ -d "$target" ]]; then
      type=directory
      mode="$(stat -c '%a' "$target")"
      hash='-'
    else
      type=absent
      mode='-'
      hash='-'
    fi
    printf '%s\t%s\t%s\t%s\n' "$rel" "$type" "$mode" "$hash" >>"$manifest"
  done <"$status_file"

  printf 'run_id=%s\ncreated_at=%s\nhost=%s\n' \
    "$run_id" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(hostname)" >"$dir/metadata"
  chmod -R go-rwx "$dir"
  ln -sfn "$id" "$BACKUP_ROOT/latest"
  printf 'backup_id=%s\n' "$id"
  printf 'backup_path=%s\n' "$dir"
}

resolve_backup_id() {
  local requested="$1" id
  if [[ "$requested" == latest ]]; then
    [[ -L "$BACKUP_ROOT/latest" ]] || return 1
    id="$(readlink -- "$BACKUP_ROOT/latest")"
  else
    id="$requested"
  fi
  [[ "$id" != . && "$id" != .. && "$id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s\n' "$id"
}

verify_backup_id() {
  local id="$1" dir="$BACKUP_ROOT/$1" manifest="$BACKUP_ROOT/$1/manifest.tsv"
  local files_root header rel type mode hash extra source parent_real files_real actual
  declare -A seen=()

  [[ -d "$dir" && ! -L "$dir" && -f "$manifest" ]] || {
    printf 'Invalid backup: %s\n' "$id" >&2
    return 1
  }
  IFS= read -r header <"$manifest" || {
    printf 'Invalid backup manifest: %s\n' "$id" >&2
    return 1
  }
  [[ "$header" == $'path\ttype\tmode\tsha256' ]] || {
    printf 'Invalid backup manifest header: %s\n' "$id" >&2
    return 1
  }
  files_root="$dir/files"
  [[ -d "$files_root" && ! -L "$files_root" ]] || {
    printf 'Invalid backup files directory: %s\n' "$id" >&2
    return 1
  }
  files_real="$(realpath -e -- "$files_root")" || {
    printf 'Cannot resolve backup files directory: %s\n' "$id" >&2
    return 1
  }

  while IFS=$'\t' read -r rel type mode hash extra; do
    [[ -n "$rel" && -n "$type" && -n "$mode" && -n "$hash" && -z "$extra" ]] || {
      printf 'Invalid backup manifest row: %s\n' "$id" >&2
      return 1
    }
    safe_relative_path "$rel" || {
      printf 'Unsafe backup path: %s\n' "$rel" >&2
      return 1
    }
    [[ -z "${seen[$rel]+present}" ]] || {
      printf 'Duplicate backup path: %s\n' "$rel" >&2
      return 1
    }
    seen["$rel"]=1

    case "$type" in
      absent)
        [[ "$mode" == - && "$hash" == - ]] || {
          printf 'Invalid absent entry: %s\n' "$rel" >&2
          return 1
        }
        ;;
      directory)
        [[ "$mode" =~ ^[0-7]{3,4}$ && "$hash" == - ]] || {
          printf 'Invalid directory entry: %s\n' "$rel" >&2
          return 1
        }
        ;;
      file | symlink)
        [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || {
          printf 'Invalid checksum entry: %s\n' "$rel" >&2
          return 1
        }
        if [[ "$type" == file ]]; then
          [[ "$mode" =~ ^[0-7]{3,4}$ && -f "$files_root/$rel" && ! -L "$files_root/$rel" ]] || {
            printf 'Missing or invalid backup file: %s\n' "$rel" >&2
            return 1
          }
        else
          [[ "$mode" == - && -L "$files_root/$rel" ]] || {
            printf 'Missing or invalid backup symlink: %s\n' "$rel" >&2
            return 1
          }
        fi
        source="$files_root/$rel"
        parent_real="$(realpath -e -- "$(dirname "$source")")" || {
          printf 'Invalid backup parent: %s\n' "$rel" >&2
          return 1
        }
        [[ "$parent_real" == "$files_real" || "$parent_real" == "$files_real/"* ]] || {
          printf 'Backup path escapes files directory: %s\n' "$rel" >&2
          return 1
        }
        if [[ "$type" == file ]]; then
          actual="$(sha256sum -- "$source" | awk '{print $1}')"
        else
          actual="$(readlink -- "$source" | sha256sum | awk '{print $1}')"
        fi
        [[ "$actual" == "$hash" ]] || {
          printf 'Backup checksum failed: %s\n' "$rel" >&2
          return 1
        }
        ;;
      *)
        printf 'Invalid backup entry type: %s\n' "$type" >&2
        return 1
        ;;
    esac
  done < <(tail -n +2 "$manifest")
}

verify_backup() {
  [[ $# -ge 2 ]] || {
    usage >&2
    exit 2
  }
  local requested="$2" id
  shift 2
  [[ $# -eq 0 && -n "$requested" ]] || {
    usage >&2
    exit 2
  }
  id="$(resolve_backup_id "$requested")" || {
    printf 'No backup found\n' >&2
    exit 2
  }
  verify_backup_id "$id"
  printf 'Backup verified: %s\n' "$id"
}

restore_backup() {
  [[ $# -ge 2 ]] || {
    usage >&2
    exit 2
  }
  local requested="$2" force=false id dir manifest rel type mode hash target source actual
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        force=true
        shift
        ;;
      *)
        printf 'Unknown restore option: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done
  [[ -n "$requested" ]] || {
    usage >&2
    exit 2
  }
  id="$(resolve_backup_id "$requested")" || {
    printf 'No backup found\n' >&2
    exit 2
  }
  dir="$BACKUP_ROOT/$id"
  manifest="$dir/manifest.tsv"
  verify_backup_id "$id" || {
    printf 'Backup verification failed: %s\n' "$id" >&2
    return 1
  }

  if [[ "$force" == false ]]; then
    read -r -p "Restore backup $id and replace current paths? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 0
  fi

  while IFS=$'\t' read -r rel type mode hash; do
    safe_relative_path "$rel" || {
      printf 'Unsafe backup path: %s\n' "$rel" >&2
      return 1
    }
    target="$HOME/$rel"
    source="$dir/files/$rel"
    if [[ "$type" == absent ]]; then
      rm -rf -- "$target"
      printf 'removed newly-created ~/%s\n' "$rel"
      continue
    fi
    if [[ "$type" == directory ]]; then
      if [[ -e "$target" && ! -d "$target" ]] || [[ -L "$target" ]]; then
        rm -rf -- "$target"
      fi
      mkdir -p "$target"
      chmod "$mode" "$target"
      printf 'restored directory metadata ~/%s\n' "$rel"
      continue
    fi
    rm -rf -- "$target"
    mkdir -p "$(dirname "$target")"
    cp -a -- "$source" "$target"
    if [[ "$type" == file ]]; then
      actual="$(sha256sum -- "$target" | awk '{print $1}')"
      [[ "$actual" == "$hash" ]] || {
        printf 'Restore checksum failed: %s\n' "$rel" >&2
        return 1
      }
      chmod "$mode" "$target"
    elif [[ "$type" == symlink ]]; then
      actual="$(readlink -- "$target" | sha256sum | awk '{print $1}')"
      [[ "$actual" == "$hash" ]] || {
        printf 'Restore symlink checksum failed: %s\n' "$rel" >&2
        return 1
      }
    fi
    printf 'restored ~/%s\n' "$rel"
  done < <(tail -n +2 "$manifest")
}

list_backups() {
  [[ -d "$BACKUP_ROOT" ]] || {
    printf 'No backups\n'
    return 0
  }
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r
}

prune_backups() {
  local keep="${2:-10}"
  [[ "$keep" =~ ^[0-9]+$ ]] || {
    printf 'Invalid retention count: %s\n' "$keep" >&2
    exit 2
  }
  [[ -d "$BACKUP_ROOT" ]] || return 0
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' |
    sort -nr |
    awk -v keep="$keep" 'NR > keep {sub(/^[^ ]+ /, ""); print}' |
    while IFS= read -r path; do
      rm -rf -- "$path"
      printf 'pruned %s\n' "$(basename "$path")"
    done
}

case "${1:-}" in
  create) create_backup "$@" ;;
  verify) verify_backup "$@" ;;
  restore) restore_backup "$@" ;;
  list) list_backups ;;
  prune) prune_backups "$@" ;;
  -h | --help | '') usage ;;
  *)
    printf 'Unknown command: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
