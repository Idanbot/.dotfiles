#!/usr/bin/env bash
# Verify the upstream kubecolor shell integration without requiring a cluster.
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
MOCK_BIN="$TMP_ROOT/bin"
FALLBACK_BIN="$TMP_ROOT/fallback-bin"
mkdir -p "$MOCK_BIN" "$FALLBACK_BIN" \
  "$TMP_ROOT/zsh-home/.oh-my-zsh" "$TMP_ROOT/bash-home"

render_zsh_template() {
  awk -v source_dir="$DOTFILES_DIR" '
    function emit(line) {
      gsub(/{{ \.chezmoi\.sourceDir }}/, source_dir, line)
      gsub(/{{ \.chezmoi\.sourceFile }}/, source_dir, line)
      gsub(/{{ \.sessionizer_dirs \| quote }}/, "\"~/Code ~/Scripts\"", line)
      gsub(/{{ \.sessionizer_dirs }}/, "~/Code ~/Scripts", line)
      gsub(/{{ \.email }}/, "test@example.com", line)
      gsub(/{{ \.name }}/, "Test User", line)
      print line
    }
    /^[[:space:]]*{{-? if \.is_wsl }}[[:space:]]*$/ {
      stack[++depth] = include
      include = 0
      next
    }
    /^[[:space:]]*{{ if not \.is_wsl }}[[:space:]]*$/ {
      stack[++depth] = include
      include = 1
      next
    }
    /^[[:space:]]*{{-? else }}[[:space:]]*$/ { include = !include; next }
    /^[[:space:]]*{{-? end }}[[:space:]]*$/ { include = stack[depth--]; next }
    BEGIN { include = 1; depth = 0 }
    { if (include) emit($0) }
  ' "$DOTFILES_DIR/dot_zshrc.tmpl" >"$TMP_ROOT/zsh-home/.zshrc"
}

cat >"$TMP_ROOT/zsh-home/.zshenv" <<'EOF'
compdef() { printf '%s\n' "$*" >>"$COMPDEF_CALLS"; }
EOF
printf '# test-only Oh My Zsh stub\n' >"$TMP_ROOT/zsh-home/.oh-my-zsh/oh-my-zsh.sh"

cat >"$MOCK_BIN/kubecolor" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECOLOR_CALLS"
printf 'kubecolor-result\n'
EOF
cat >"$MOCK_BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS"
printf 'kubectl-result\n'
EOF
chmod +x "$MOCK_BIN/kubecolor" "$MOCK_BIN/kubectl"
ln -s "$MOCK_BIN/kubectl" "$FALLBACK_BIN/kubectl"
render_zsh_template

run_zsh() {
  local path_prefix="$1"
  local command_string="$2"
  PATH="$path_prefix:/usr/bin:/bin" \
    HOME="$TMP_ROOT/zsh-home" \
    ZDOTDIR="$TMP_ROOT/zsh-home" \
    TERM=xterm-256color \
    COMPDEF_CALLS="$TMP_ROOT/zsh-compdef" \
    KUBECOLOR_CALLS="$TMP_ROOT/zsh-kubecolor" \
    KUBECTL_CALLS="$TMP_ROOT/zsh-kubectl" \
    zsh -di -c 'source "$ZDOTDIR/.zshrc"; eval "$1"' zsh "$command_string"
}

run_zsh "$MOCK_BIN" '[[ "$(alias kubectl)" == "kubectl=kubecolor" ]]'
grep -Fxq 'kubecolor=kubectl' "$TMP_ROOT/zsh-compdef"
[[ "$(run_zsh "$MOCK_BIN" 'kubectl get pods')" == kubecolor-result ]]
grep -Fxq 'get pods' "$TMP_ROOT/zsh-kubecolor"

if run_zsh "$FALLBACK_BIN" '[[ -z "${aliases[kubectl]:-}" ]]' >/dev/null 2>&1; then
  :
else
  printf 'Zsh created a kubecolor alias when kubecolor was unavailable\n' >&2
  exit 1
fi

mkdir -p "$TMP_ROOT/bash-local-home/.local/bin" "$TMP_ROOT/bash-fallback-home"
cat >"$TMP_ROOT/bash-local-home/.bash_aliases" <<'EOF'
__start_kubectl() { :; }
EOF
cp "$TMP_ROOT/bash-local-home/.bash_aliases" "$TMP_ROOT/bash-fallback-home/.bash_aliases"
ln -s "$MOCK_BIN/kubecolor" "$TMP_ROOT/bash-local-home/.local/bin/kubecolor"
ln -s "$MOCK_BIN/kubectl" "$TMP_ROOT/bash-local-home/.local/bin/kubectl"

run_bash() {
  local home_dir="$1"
  local path_prefix="$2"
  local command_string="$3"
  PATH="$path_prefix:/usr/bin:/bin" \
    HOME="$home_dir" \
    KUBECOLOR_CALLS="$TMP_ROOT/bash-kubecolor" \
    KUBECTL_CALLS="$TMP_ROOT/bash-kubectl" \
    bash --noprofile --norc -i -c \
    'source "$1"; eval "$2"' bash "$DOTFILES_DIR/dot_bashrc" "$command_string"
}

run_bash "$TMP_ROOT/bash-local-home" /usr/bin 'alias kubectl' |
  grep -Fq "kubectl='kubecolor'"
run_bash "$TMP_ROOT/bash-local-home" /usr/bin 'complete -p kubecolor' |
  grep -Fq '__start_kubectl'
[[ "$(run_bash "$TMP_ROOT/bash-local-home" /usr/bin 'kubectl get pods')" == kubecolor-result ]]
grep -Fxq 'get pods' "$TMP_ROOT/bash-kubecolor"

if run_bash "$TMP_ROOT/bash-fallback-home" "$FALLBACK_BIN" \
  '[[ -z "$(alias kubectl 2>/dev/null)" ]]' >/dev/null 2>&1; then
  :
else
  printf 'Bash created a kubecolor alias when kubecolor was unavailable\n' >&2
  exit 1
fi

if DOTFILES_DISABLE_KUBECOLOR=1 run_bash "$TMP_ROOT/bash-local-home" /usr/bin \
  '[[ -z "$(alias kubectl 2>/dev/null)" ]]' >/dev/null 2>&1; then
  :
else
  printf 'DOTFILES_DISABLE_KUBECOLOR did not disable the alias\n' >&2
  exit 1
fi

printf 'kubecolor shell integration test passed\n'
