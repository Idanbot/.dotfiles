#!/usr/bin/env bash
# Repository architecture contracts that should never regress silently.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
FAILED=0
pass() { printf '  [PASS] %s\n' "$*"; }
fail() {
  printf '  [FAIL] %s\n' "$*"
  FAILED=1
}

printf '\n== Repository Layout ==\n'

required=(
  scripts/install.sh scripts/lib.sh scripts/environment.sh scripts/backup.sh
  scripts/reconcile-packages.sh scripts/doctor.sh scripts/validate-neovim.sh
  profiles/minimal.conf profiles/base.conf profiles/developer.conf profiles/agent.conf
  profiles/cloud.conf profiles/full.conf agents.yaml .chezmoiversion
  .github/e2e/compose.yaml tests/e2e/test-install.sh
  tests/test-external-tools.sh
)
for path in "${required[@]}"; do
  [[ -e "$DOTFILES_DIR/$path" ]] && pass "$path exists" || fail "$path is missing"
done

if find "$DOTFILES_DIR" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.sh.tmpl' \) | grep -q .; then
  fail "shell entrypoints must live under scripts/, tests/, or .chezmoiscripts/"
else
  pass "no root-level shell entrypoints"
fi

INSTALL="$DOTFILES_DIR/scripts/install.sh"
for expected in \
  'run_stage "section-$section"' \
  'DOTFILES_FAIL_AT' \
  'scripts/backup.sh create' \
  'chezmoi apply --source="$CHEZMOI_SOURCE" --exclude=scripts --force' \
  'chmod 600 "$LOG_FILE" "$EVENT_LOG"' \
  'orchestrator=explicit'; do
  grep -Fq "$expected" "$INSTALL" && pass "installer contract: $expected" || fail "installer missing: $expected"
done

if grep -R -E 'curl[^|]*(\||[[:space:]])[[:space:]]*(ba)?sh|wget[^|]*\|[[:space:]]*(ba)?sh' \
  "$DOTFILES_DIR/.chezmoiscripts" "$DOTFILES_DIR/scripts" --include='*.sh' --include='*.tmpl' | grep -v 'scripts/install.sh:.*curl -fsSL'; then
  fail "runtime scripts contain an unverified download-to-shell pipeline"
else
  pass "no runtime download-to-shell pipelines"
fi

if grep -Rq 'checksum: null' "$DOTFILES_DIR/packages.lock" "$DOTFILES_DIR/packages.meta.yaml"; then
  fail "package integrity contains null checksums"
else
  pass "package integrity declarations are non-null"
fi

if grep -Eq 'sha256: [0-9a-f]{64}$' "$DOTFILES_DIR/.chezmoiexternal.yaml"; then
  fail "external SHA256 values must be quoted for chezmoi's HexBytes decoder"
else
  pass "external SHA256 values use chezmoi-compatible quoted strings"
fi

if grep -Rq '@anthropic-ai/antigravity-cli' "$DOTFILES_DIR" \
  --exclude-dir=.git --exclude=test-repo-layout.sh; then
  fail "Antigravity must not be substituted with an unrelated npm package"
else
  pass "Antigravity remains an explicit manual capability"
fi

if grep -Fq 'load_nvm' "$DOTFILES_DIR/.chezmoiscripts/run_once_04-install-languages.sh.tmpl" ||
  grep -Fq 'nvm.sh' "$DOTFILES_DIR/dot_zshrc.tmpl"; then
  fail "Node still depends on shell-time NVM initialization"
else
  pass "Node uses stable user-local shims"
fi

if grep -Fq 'npm_install_global @oh-my-pi/pi-coding-agent' \
  "$DOTFILES_DIR/.chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl"; then
  fail "OMP npm installation requires an undeclared Bun runtime"
else
  pass "OMP uses its checksum-pinned standalone release"
fi

for preserved in .bash_history .zsh_history .lesshst '.zcompdump*' .zsh_sessions/ .local/share/zsh/; do
  grep -Fxq "$preserved" "$DOTFILES_DIR/.chezmoiignore" && pass "preserves $preserved" || fail "missing preservation rule: $preserved"
done

for metadata in artifacts/ docs/ .gitleaks.toml .yamllint.yml; do
  grep -Fxq "$metadata" "$DOTFILES_DIR/.chezmoiignore" && pass "ignores repo metadata $metadata" || fail "missing metadata ignore: $metadata"
done

for local_path in \
  .config/dotfiles/local.zsh .config/dotfiles/local.bash \
  .config/dotfiles/local.tmux.conf .config/dotfiles/machine.conf \
  .config/git/config.local .ssh/config.local; do
  grep -Fxq "$local_path" "$DOTFILES_DIR/.chezmoiignore" && pass "local-only $local_path" || fail "missing local-only rule: $local_path"
done

if grep -Fq 'set-environment -g TMUX_PLUGIN_MANAGER_PATH "$HOME/.tmux/plugins/"' \
  "$DOTFILES_DIR/dot_tmux.conf.tmpl"; then
  pass "tmux declares the TPM plugin path before background initialization"
else
  fail "tmux must declare TMUX_PLUGIN_MANAGER_PATH before TPM initialization"
fi

if grep -Fq "set -g @plugin 'tmux-plugins/tpm'" "$DOTFILES_DIR/dot_tmux.conf.tmpl"; then
  fail "checksum-pinned TPM must not attempt to Git-manage itself"
else
  pass "chezmoi remains the sole owner of the pinned TPM installation"
fi

[[ "$FAILED" -eq 0 ]] || exit 1
printf 'Repository layout test passed\n'
