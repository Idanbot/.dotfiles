# Definitions only: no cluster requests or cache warming at shell startup.
zstyle ':fzf-tab:complete:kfzf:*' fzf-preview '
  if [[ "$word" == */*/* ]]; then
    sleep 0.15
    local -a args
    local i
    for ((i = 2; i <= ${#words}; i++)); do
      case "${words[i]}" in
        --context|-n|--namespace)
          (( i < ${#words} )) && args+=("${words[i]}" "${words[i+1]}")
          (( i++ ))
          ;;
        --context=*|--namespace=*) args+=("${words[i]}") ;;
      esac
    done
    command kfzf "${args[@]}" --preview "$word" 2>&1
  fi
'
local -a _kfzf_flags
zstyle -a ':fzf-tab:*' fzf-flags _kfzf_flags
zstyle ':fzf-tab:complete:kfzf:*' fzf-flags "${_kfzf_flags[@]}" '--preview-window=right:60%:wrap'
unset _kfzf_flags
