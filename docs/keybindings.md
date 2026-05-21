# Keybindings

Generated from tmux and zsh config. Regenerate with:

```bash
./scripts/generate-keybinding-docs.sh
```

## tmux

| Key | Action |
|-----|--------|
| C-s | `send-prefix` |
| r | `source-file ~/.tmux.conf \; display-message "Config reloaded!"` |
| 'C-h' | `if-shell "$is_vim" 'send-keys C-h'  'select-pane -L'` |
| 'C-j' | `if-shell "$is_vim" 'send-keys C-j'  'select-pane -D'` |
| 'C-k' | `if-shell "$is_vim" 'send-keys C-k'  'select-pane -U'` |
| 'C-l' | `if-shell "$is_vim" 'send-keys C-l'  'select-pane -R'` |
| C-l | `send-keys 'C-l'` |
| H | `resize-pane -L 5` |
| L | `resize-pane -R 5` |
| J | `resize-pane -D 5` |
| K | `resize-pane -U 5` |
| | | `split-window -h -c "#{pane_current_path}"` |
| - | `split-window -v -c "#{pane_current_path}"` |
| ^ | `last-window` |
| f | `run-shell "tmux neww ~/.local/bin/tmux-sessionizer"` |
| i | `display-popup -w 80% -h 70% -E 'bash -lc "read -rp \"cht.sh query: \" query; [[ -n $query ]] \|\| exit 0; curl -fsSL \"https://cht.sh/${query// /+}\" \| less -R"'` |
| M-n | `display-popup -w 80% -h 80% -E "tmux new-session -A -s scratchpad"` |
| M-s | `display-popup -E "tmux list-sessions \| less"` |
| M-w | `display-popup -E "tmux list-windows \| less"` |
| M-g | `display-popup -w 90% -h 90% -d "#{pane_current_path}" -E 'bash -lc "command -v lazygit >/dev/null && exec lazygit \|\| { printf \"lazygit not found\\n\\nPress enter to close...\"; read -r _; }"'` |
| M-d | `display-popup -w 90% -h 85% -d "#{pane_current_path}" -E 'bash -lc "command -v docker >/dev/null \|\| { printf \"docker not found\\n\\nPress enter to close...\"; read -r _; exit 0; }; docker ps; printf \"\\nImages:\\n\"; docker images \| head -25; printf \"\\nPress enter to close...\"; read -r _"'` |
| M-k | `display-popup -w 90% -h 85% -d "#{pane_current_path}" -E 'bash -lc "command -v kubectl >/dev/null \|\| { printf \"kubectl not found\\n\\nPress enter to close...\"; read -r _; exit 0; }; printf \"Contexts:\\n\"; kubectl config get-contexts 2>/dev/null \|\| true; printf \"\\nNamespaces:\\n\"; kubectl get namespaces 2>/dev/null \|\| true; printf \"\\nPress enter to close...\"; read -r _"'` |
| M-p | `display-popup -w 90% -h 85% -d "#{pane_current_path}" -E 'bash -lc "test -x ~/.local/bin/tmux-sessionizer && exec ~/.local/bin/tmux-sessionizer \|\| { printf \"tmux-sessionizer not found or not executable\\n\\nPress enter to close...\"; read -r _; }"'` |
| M-m | `display-popup -w 80% -h 80% -E "rmpc"` |
| M-u | `display-popup -w 80% -h 70% -d "#{pane_current_path}" -E 'bash -lc "printf \"Host: %s\\nPath: %s\\nKernel: %s\\n\\n\" \"$(hostname -s)\" \"$PWD\" \"$(uname -srmo)\"; command -v docker >/dev/null && docker context ls 2>/dev/null \|\| true; printf \"\\n\"; command -v kubectl >/dev/null && kubectl config get-contexts 2>/dev/null \|\| true; printf \"\\nPress enter to close...\"; read -r _"'` |
| M-e | `display-popup -w 80% -h 70% -d "#{pane_current_path}" -E 'bash -lc "printf \"WSL distro: %s\\nHost: %s\\nLinux path: %s\\nWindows path: \" \"${WSL_DISTRO_NAME:-unknown}\" \"$(hostname -s)\" \"$PWD\"; command -v wslpath >/dev/null && wslpath -w \"$PWD\" \|\| printf \"n/a\"; printf \"\\n\\nDISPLAY=%s\\nWAYLAND_DISPLAY=%s\\nWSLg=%s\\n\\n\" \"${DISPLAY:-unset}\" \"${WAYLAND_DISPLAY:-unset}\" \"${WSLGd:-unset}\"; command -v explorer.exe >/dev/null && printf \"explorer.exe is available\\n\" \|\| printf \"explorer.exe not found\\n\"; command -v clip.exe >/dev/null && printf \"clip.exe is available\\n\" \|\| printf \"clip.exe not found\\n\"; printf \"\\nPress enter to close...\"; read -r _"'` |
| M-o | `display-popup -w 70% -h 30% -d "#{pane_current_path}" -E 'bash -lc "command -v explorer.exe >/dev/null && { explorer.exe .; printf \"Opened current directory in Windows Explorer.\"; } \|\| printf \"explorer.exe not found\"; printf \"\\n\\nPress enter to close...\"; read -r _"'` |
| M-h | `display-popup -w 80% -h 80% -E "btop"` |
| y | `setw synchronize-panes \; display-message "synchronize-panes #{?synchronize-panes,on,off}"` |

## zsh aliases

| Alias | Command |
|-------|---------|
| c | `"clear"` |
| reload | `"source ~/.zshrc"` |
| reload-bash | `"source ~/.bashrc"` |
| fd | `"fdfind"` |
| rg | `"rg --pretty --column --line-number"` |
| vlg | `valgrind --leak-check=yes --track-origins=yes` |
| cpfile | `xclip -selection clipboard <` |
| gd | `gcc -ansi -pedantic-errors -Wall -Wextra -g` |
| gc | `gcc -ansi -pedantic-errors -Wall -Wextra -DNDEBUG -O3` |
| gd9 | `gcc -std=c99 -pedantic-errors -Wall -Wextra -g` |
| gc9 | `gcc -std=c99 -pedantic-errors -Wall -Wextra -DNDEBUG -O3` |
| ssh | `TERM=xterm-256color ssh` |
| ls | `eza --icons=always -hg` |
| cat | `bat --paging=never --style=full` |
| tm | `tmuxp load -y -s "$(basename $PWD \| tr . _)" $(tmuxp ls \| fzf)` |
| ytmp4 | `yt-dlp -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"` |
| cheat | `"curl -s https://cht.sh/"` |
| dotfiles-doctor | `"echo '=== SSH Agent ===' && systemctl --user status ssh-agent.service \| head -n 3 && echo '\n=== Chezmoi State ===' && chezmoi status && echo '\n=== Template Check ===' && bash ~/.dotfiles/tests/test-templates.sh"` |
| explorer | `"explorer.exe"` |
| cbcopy | `"clip.exe"` |
| cbpaste | `"powershell.exe -NoProfile -Command Get-Clipboard"` |
