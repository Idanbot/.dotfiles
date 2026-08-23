#!/usr/bin/env bash
# Shared per-destination conflict handling for the bootstrap installer.

# This file is sourced by scripts/install.sh. It intentionally does not enable
# shell options so it can inherit the caller's strict-mode settings.

dotfiles_conflict_status_path() {
  local line="$1" path
  path="${line:3}"
  path="${path#"${path%%[![:space:]]*}"}"
  printf '%s\n' "$path"
}

dotfiles_conflict_destination_modified() {
  local line="$1" rel target destination_state
  rel="$(dotfiles_conflict_status_path "$line")"
  destination_state="${line:1:1}"
  target="$HOME/$rel"
  [[ "$destination_state" =~ [AMDR] ]] && [[ -f "$target" || -L "$target" ]]
}

dotfiles_conflict_diff() {
  local source="$1" rel="$2" limit="${3:-160}" output status=0 line count=0 total
  output="$(chezmoi diff --source="$source" "$rel" 2>&1)" || status=$?
  if [[ -z "$output" ]]; then
    printf 'diff unavailable (chezmoi exit %s)\n' "$status"
    return 0
  fi

  total="$(wc -l <<<"$output" | tr -d ' ')"
  while IFS= read -r line; do
    ((count++)) || true
    ((count <= limit)) || break
    line="$(printf '%s\n' "$line" | sed -E \
      -e 's/((token|password|secret|api[_-]?key|authorization|bearer)[=:][[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig')"
    printf '%s\n' "$line"
  done <<<"$output"
  if ((total > limit)); then
    printf '... %s more diff line(s); run chezmoi diff %s for the full diff\n' \
      "$((total - limit))" "$rel"
  fi
}

dotfiles_conflict_is_mergeable() {
  local rel="$1" target
  target="$HOME/$rel"
  [[ -f "$target" && ! -L "$target" ]] || return 1
  case "$rel" in
    .bash_aliases | .bashrc | .gitconfig | .profile | .tmux.conf | .zshrc | .ssh/config | .ssh/config.local | .config/git/* | *.conf | *.ini | *.sh | *.zsh) ;;
    *)
      return 1
      ;;
  esac
  [[ ! -s "$target" ]] || LC_ALL=C grep -Iq . "$target"
}

dotfiles_conflict_merge_append() {
  local source="$1" rel="$2" target
  local managed_file local_file merged_file managed_hash start_marker end_marker
  target="$HOME/$rel"

  dotfiles_conflict_is_mergeable "$rel" || return 2

  managed_file="$(mktemp)"
  local_file="$(mktemp)"
  merged_file="$(mktemp "$(dirname "$target")/.dotfiles-merge.XXXXXX")"
  trap 'rm -f "$managed_file" "$local_file" "$merged_file"' RETURN

  if ! chezmoi cat --source="$source" "$rel" >"$managed_file"; then
    return 1
  fi
  [[ ! -s "$managed_file" ]] || LC_ALL=C grep -Iq . "$managed_file" || return 2

  managed_hash="$(sha256sum "$managed_file" | awk '{print $1}')"
  start_marker="# >>> dotfiles merged local content sha256=$managed_hash >>>"
  end_marker='# <<< dotfiles merged local content <<<'

  if grep -Fqx "$start_marker" "$target" && grep -Fqx "$end_marker" "$target"; then
    return 3
  fi

  if grep -Fq '# >>> dotfiles merged local content sha256=' "$target" &&
    grep -Fqx "$end_marker" "$target"; then
    awk '
      /^# >>> dotfiles merged local content sha256=/ { inside = 1; next }
      /^# <<< dotfiles merged local content <<</ { inside = 0; found = 1; next }
      inside { print }
      END { if (!found) exit 1 }
    ' "$target" >"$local_file"
  else
    cp -p -- "$target" "$local_file"
  fi

  cat "$managed_file" >"$merged_file"
  if [[ -s "$managed_file" ]] &&
    [[ "$(tail -c 1 "$managed_file" | od -An -t x1 | tr -d '[:space:]')" != 0a ]]; then
    printf '\n' >>"$merged_file"
  fi
  printf '%s\n' "$start_marker" >>"$merged_file"
  cat "$local_file" >>"$merged_file"
  if [[ -s "$local_file" ]] &&
    [[ "$(tail -c 1 "$local_file" | od -An -t x1 | tr -d '[:space:]')" != 0a ]]; then
    printf '\n' >>"$merged_file"
  fi
  printf '%s\n' "$end_marker" >>"$merged_file"
  chmod --reference="$target" "$merged_file"
  mv -f -- "$merged_file" "$target"
  rm -f "$managed_file" "$local_file"
  trap - RETURN
}

dotfiles_conflict_show_diff() {
  local source="$1" rel="$2" limit="${3:-160}" line
  while IFS= read -r line; do
    log_info "  $line"
  done < <(dotfiles_conflict_diff "$source" "$rel" "$limit")
}

dotfiles_conflict_prompt() {
  local source="$1" rel="$2" choice target
  target="$HOME/$rel"
  DOTFILES_CONFLICT_ACTION=""

  if [[ "${CONFLICT_AUTO_APPROVE:-false}" == true ]]; then
    DOTFILES_CONFLICT_ACTION=replace
    return 0
  fi
  if [[ ! -t 0 && ! -r /dev/tty ]]; then
    log_warn "No terminal available for conflict choice; replacing after backup"
    DOTFILES_CONFLICT_ACTION=replace
    return 0
  fi

  while :; do
    printf '\nConflict: ~/%s differs from the managed version\n' "$rel" >&2
    printf '  [s]kip/do nothing  [r]eplace  [m]erge/append  [a]ll replace\n' >&2
    printf '  [k]eep all  [d]iff again  [q]uit\n' >&2
    read_user 'Choice [s]: ' choice
    case "${choice:-s}" in
      s | skip | nothing | do-nothing)
        DOTFILES_CONFLICT_ACTION=skip
        return 0
        ;;
      r | replace | overwrite)
        DOTFILES_CONFLICT_ACTION=replace
        return 0
        ;;
      m | merge | append)
        if dotfiles_conflict_is_mergeable "$rel" &&
          [[ -f "$target" && ! -L "$target" ]]; then
          DOTFILES_CONFLICT_ACTION=merge
          return 0
        fi
        log_warn "Append merge is supported only for regular text configuration files"
        ;;
      a | all | all-replace | all-overwrite)
        DOTFILES_CONFLICT_ACTION=replace-all
        return 0
        ;;
      k | all-skip | skip-all | keep-all)
        DOTFILES_CONFLICT_ACTION=skip-all
        return 0
        ;;
      d | diff)
        dotfiles_conflict_show_diff "$source" "$rel" "${CONFLICT_DIFF_LINES:-160}"
        ;;
      q | quit | exit)
        DOTFILES_CONFLICT_ACTION=quit
        return 0
        ;;
      *)
        log_warn "Unknown conflict choice: $choice"
        ;;
    esac
  done
}

dotfiles_apply_selected_conflicts() {
  local -a apply_targets=()
  local line rel action all_action="" merge_status
  local had_conflict=false

  if [[ "${CONFLICT_AUTO_APPROVE:-false}" == true ]]; then
    all_action=replace
    log_info "Non-interactive conflict mode: replacing pending destinations after backup"
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    rel="$(dotfiles_conflict_status_path "$line")"
    [[ -n "$rel" ]] || continue

    # Chezmoi reports parent directories as well as their files. Applying a
    # parent would bypass a user's decision for a skipped child, so directory
    # entries are handled by --include=dirs below and never applied directly.
    if [[ -d "$HOME/$rel" && ! -L "$HOME/$rel" ]]; then
      continue
    fi

    action=replace
    if dotfiles_conflict_destination_modified "$line"; then
      had_conflict=true
      if [[ "$all_action" == replace || "$all_action" == skip ]]; then
        action="$all_action"
      else
        log_warn "Existing destination differs: ~/$rel"
        dotfiles_conflict_show_diff "$CHEZMOI_SOURCE" "$rel" "${CONFLICT_DIFF_LINES:-160}"
        dotfiles_conflict_prompt "$CHEZMOI_SOURCE" "$rel"
        action="$DOTFILES_CONFLICT_ACTION"
      fi
    fi

    case "$action" in
      replace)
        apply_targets+=("$rel")
        ;;
      replace-all)
        all_action=replace
        apply_targets+=("$rel")
        ;;
      skip)
        log_skip "Preserving ~/$rel"
        ;;
      skip-all)
        all_action=skip
        log_skip "Preserving ~/$rel and later conflicts"
        ;;
      merge)
        if dotfiles_conflict_merge_append "$CHEZMOI_SOURCE" "$rel"; then
          log_success "Merged managed content into ~/$rel (local content preserved after it)"
        else
          merge_status=$?
          if [[ "$merge_status" -eq 3 ]]; then
            log_skip "$HOME/$rel already contains the current merged managed content"
          else
            log_error "Unable to append-merge ~/$rel"
            return 1
          fi
        fi
        ;;
      quit)
        log_warn "Conflict resolution cancelled before configuration apply"
        return 130
        ;;
      *)
        log_error "Unknown conflict action: $action"
        return 2
        ;;
    esac
  done <<<"$CHEZMOI_STATUS_OUTPUT"

  if [[ "$had_conflict" == false ]]; then
    if ! chezmoi apply --source="$CHEZMOI_SOURCE" --exclude=scripts --force; then
      return 1
    fi
    return 0
  fi

  if [[ ${#apply_targets[@]} -gt 0 ]]; then
    log_info "Applying ${#apply_targets[@]} selected managed file(s)"
    if ! chezmoi apply --source="$CHEZMOI_SOURCE" --exclude=scripts --force "${apply_targets[@]}"; then
      return 1
    fi
  else
    log_info "No managed files selected for replacement"
  fi
  # Keep directory creation and verified externals convergent without touching
  # any file that the user explicitly skipped or merged.
  if ! chezmoi apply --source="$CHEZMOI_SOURCE" --include=dirs,externals --force; then
    return 1
  fi
}
