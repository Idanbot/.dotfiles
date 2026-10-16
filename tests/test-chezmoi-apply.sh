#!/usr/bin/env bash
# test-chezmoi-apply.sh — Render/apply chezmoi into a temporary HOME
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT=$(mktemp -d)
TMP_SOURCE="$TMP_ROOT/source"
trap 'rm -rf "$TMP_ROOT"' EXIT

if ! command -v chezmoi >/dev/null 2>&1; then
  echo "chezmoi not installed; skipping chezmoi apply fixture"
  exit 0
fi

mkdir -p "$TMP_SOURCE"
tar -C "$DOTFILES_DIR" \
  --exclude=.git \
  --exclude=artifacts \
  --exclude=.chezmoiexternal.yaml \
  -cf - . | tar -C "$TMP_SOURCE" -xf -

run_fixture() {
  local profile="$1"
  local is_wsl="$2"
  local expected_history='fixture-history-must-survive'
  local expected_overlay='export FIXTURE_LOCAL=preserved'
  local expected_access_state='fixture-cloudflare-session-must-survive'

  export HOME="$TMP_ROOT/home-$profile"
  export DOTFILES_WSL="$is_wsl"
  mkdir -p \
    "$HOME/.config/chezmoi" \
    "$HOME/.config/dotfiles" \
    "$HOME/.cloudflared"

  printf '%s\n' "$expected_history" >"$HOME/.zsh_history"
  printf '%s\n' "$expected_overlay" >"$HOME/.config/dotfiles/local.zsh"
  printf '%s\n' "$expected_access_state" >"$HOME/.cloudflared/cert.pem"
  chmod 600 \
    "$HOME/.zsh_history" \
    "$HOME/.config/dotfiles/local.zsh" \
    "$HOME/.cloudflared/cert.pem"

  cat >"$HOME/.config/chezmoi/chezmoi.yaml" <<EOF
data:
  name: "Test User"
  email: "test@example.com"
  sessionizer_dirs: "~/Code ~/Scripts"
  is_wsl: $is_wsl
EOF

  chezmoi init --source="$TMP_SOURCE" \
    --promptString="Full name=Test User" \
    --promptString="Git email=test@example.com" \
    --promptString="tmux-sessionizer search dirs (space-separated)=~/Code ~/Scripts"
  chezmoi apply --source="$TMP_SOURCE" --destination="$HOME" --force --exclude=scripts,externals

  test -f "$HOME/.zshrc"
  test -f "$HOME/.tmux.conf"
  test -f "$HOME/.gitconfig"
  test -f "$HOME/.config/herdr/config.toml"
  test -f "$HOME/.config/dotfiles/agents.yaml"
  test -f "$HOME/.config/agents/AGENTS.md"
  test -x "$HOME/.local/bin/agent-mcp"
  test -x "$HOME/.local/bin/dot-privacy"
  test -f "$HOME/.config/dotfiles/privacy.sh"
  test -f "$HOME/.config/rtk/config.toml"
  test -x "$HOME/.local/bin/cloudflare-ssh"
  test -x "$HOME/.local/bin/git-credential-dotfiles"
  test -x "$HOME/.local/bin/ssh-key-load"
  test -x "$HOME/.local/bin/tmux-cheat-sheet"
  test -x "$HOME/.local/bin/tmux-help"
  test -x "$HOME/.local/bin/tmux-kube-status"
  test ! -e "$HOME/.ssh/sockets"
  grep -Fq 'prefix = "ctrl+s"' "$HOME/.config/herdr/config.toml"
  grep -Fq 'workspace:' "$HOME/.config/dotfiles/agents.yaml"
  for instruction_path in \
    "$HOME/.codex/AGENTS.md" \
    "$HOME/.claude/CLAUDE.md" \
    "$HOME/.gemini/GEMINI.md" \
    "$HOME/.config/opencode/AGENTS.md" \
    "$HOME/.omp/agent/AGENTS.md"; do
    test -L "$instruction_path"
    test "$(readlink -f "$instruction_path")" = \
      "$(readlink -f "$HOME/.config/agents/AGENTS.md")"
  done
  test "$(cat "$HOME/.zsh_history")" = "$expected_history"
  test "$(cat "$HOME/.config/dotfiles/local.zsh")" = "$expected_overlay"
  test "$(cat "$HOME/.cloudflared/cert.pem")" = "$expected_access_state"
  test "$(stat -c '%a' "$HOME/.zsh_history")" = 600
  test "$(stat -c '%a' "$HOME/.config/dotfiles/local.zsh")" = 600
  test "$(stat -c '%a' "$HOME/.cloudflared/cert.pem")" = 600

  if [[ "$is_wsl" == true ]]; then
    test ! -e "$HOME/.config/kitty"
  else
    test -f "$HOME/.config/kitty/kitty.conf"
  fi

  echo "chezmoi apply fixture passed ($profile)"
}

run_fixture native false
run_fixture wsl true

# Target arguments must resolve under HOME even when launched from the checkout.
(
  export HOME="$TMP_ROOT/conflict-home"
  export CHEZMOI_SOURCE="$TMP_ROOT/conflict-source"
  mkdir -p "$HOME" "$CHEZMOI_SOURCE" "$TMP_ROOT/unrelated"
  printf 'export MANAGED_ALIAS=1\n' >"$CHEZMOI_SOURCE/dot_bash_aliases"
  printf 'export MANAGED_RC=1\n' >"$CHEZMOI_SOURCE/dot_bashrc"
  printf 'export MANAGED_PROFILE=1\n' >"$CHEZMOI_SOURCE/dot_profile"
  printf 'export LOCAL_ALIAS=1\n' >"$HOME/.bash_aliases"
  printf 'export LOCAL_RC=1\n' >"$HOME/.bashrc"
  log_info() { printf '%s\n' "$*"; }
  log_warn() { printf '%s\n' "$*"; }
  log_error() { printf '%s\n' "$*" >&2; }
  log_skip() { printf '%s\n' "$*"; }
  # shellcheck source=../scripts/conflicts.sh
  source "$DOTFILES_DIR/scripts/conflicts.sh"
  export CONFLICT_AUTO_APPROVE=true
  for working_dir in "$CHEZMOI_SOURCE" "$TMP_ROOT/unrelated"; do
    cd "$working_dir"
    printf 'export LOCAL_RC=1\n' >"$HOME/.bashrc"
    export CHEZMOI_STATUS_OUTPUT
    CHEZMOI_STATUS_OUTPUT="$(chezmoi status --source="$CHEZMOI_SOURCE" --exclude=scripts)"
    dotfiles_apply_selected_conflicts
    grep -Fxq 'export MANAGED_RC=1' "$HOME/.bashrc"
    grep -Fxq 'export MANAGED_PROFILE=1' "$HOME/.profile"
    printf 'export LOCAL_ALIAS=1\n' >"$HOME/.bash_aliases"
    preview="$(dotfiles_conflict_diff "$CHEZMOI_SOURCE" .bash_aliases)"
    grep -Fq '+export MANAGED_ALIAS=1' <<<"$preview"
    dotfiles_conflict_merge_append "$CHEZMOI_SOURCE" .bash_aliases
    grep -Fxq 'export MANAGED_ALIAS=1' "$HOME/.bash_aliases"
    grep -Fxq 'export LOCAL_ALIAS=1' "$HOME/.bash_aliases"
  done
  printf 'Conflict targets resolve under HOME from checkout and unrelated directories\n'
)
