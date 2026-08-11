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
  scripts/download-cache.sh
  scripts/e2e-shell.sh scripts/update-packages.sh scripts/install-kitty.sh
  scripts/e2e-report.sh scripts/performance-report.sh scripts/performance-history.sh scripts/classify-ci-run.sh
  scripts/update-kitty.sh dot_local/bin/executable_update-kitty
  profiles/minimal.conf profiles/base.conf profiles/developer.conf profiles/agent.conf
  profiles/cloud.conf profiles/full.conf agents.yaml .chezmoiversion
  .github/e2e/compose.yaml tests/e2e/test-install.sh tests/test-e2e-shell.sh
  tests/test-external-tools.sh tests/test-herdr-config.sh tests/test-tmux-config.sh tests/test-update-packages.sh
  tests/test-mutable-installers.sh
  tests/test-kitty.sh tests/test-cloud-context.sh tests/test-cloud-context-starship.sh tests/test-dot-doctor.sh
  tests/test-e2e-report.sh tests/test-performance-report.sh tests/test-performance-history.sh
  tests/test-ci-outcome.sh tests/test-network-faults.sh tests/test-download-cache.sh
  tests/test-ci-operations.sh tests/test-system-configuration.sh
  tests/test-npm-global-cli.sh tests/test-ubuntu-package-tools.sh tests/test-agent-mcp.sh
  tests/test-ssh-access.sh
  .github/workflows/ci-outcome.yml .github/workflows/grouped-upgrades.yml
  .github/workflows/native-vm-e2e.yml
  dot_local/bin/executable_cloud-context dot_local/bin/executable_agent-mcp
  dot_local/bin/executable_cloudflare-ssh dot_local/bin/executable_ssh-key-load
  dot_config/herdr/config.toml dot_config/dotfiles/agents.yaml.tmpl
  dot_config/agents/AGENTS.md dot_codex/symlink_AGENTS.md
  dot_claude/symlink_CLAUDE.md dot_config/opencode/symlink_AGENTS.md
  dot_gemini/symlink_GEMINI.md dot_omp/agent/symlink_AGENTS.md
)
for path in "${required[@]}"; do
  [[ -e "$DOTFILES_DIR/$path" ]] && pass "$path exists" || fail "$path is missing"
done

if grep -Fq 'cache [status|prune]' "$DOTFILES_DIR/dot_local/bin/executable_dot" &&
  grep -Fq 'scripts/download-cache.sh' "$DOTFILES_DIR/dot_local/bin/executable_dot"; then
  pass "dot exposes verified download cache maintenance"
else
  fail "dot is missing verified download cache maintenance"
fi

CI_WORKFLOW="$DOTFILES_DIR/.github/workflows/ci.yml"
if grep -Fq 'name: Version and Checksum Report' "$CI_WORKFLOW" &&
  grep -Fq './scripts/update-packages.sh --check --report "$UPGRADE_REPORT"' "$CI_WORKFLOW" &&
  grep -Fq 'cat "$UPGRADE_REPORT" >>"$GITHUB_STEP_SUMMARY"' "$CI_WORKFLOW"; then
  pass "push/PR CI publishes the non-mutating upgrade report"
else
  fail "push/PR CI is missing the version/checksum report"
fi

if grep -Fq 'tests/test-e2e-report.sh "$PWD"' "$CI_WORKFLOW" &&
  grep -Fq 'tests/test-performance-report.sh "$PWD"' "$CI_WORKFLOW" &&
  grep -Fq 'name: Publish performance budget report' "$CI_WORKFLOW"; then
  pass "CI validates structured E2E reports and publishes performance budgets"
else
  fail "CI is missing E2E report or performance budget coverage"
fi

CLOUD_INSTALLER="$DOTFILES_DIR/.chezmoiscripts/run_once_05-install-containers-cloud.sh.tmpl"
if grep -Fq '/etc/apt/sources.list.d/azure-cli.sources' "$CLOUD_INSTALLER" &&
  grep -Fq '/etc/apt/sources.list.d/azure-cli.list' "$CLOUD_INSTALLER" &&
  grep -Fq 'reconcile_apt_source' "$CLOUD_INSTALLER"; then
  pass "Azure CLI repository converges legacy and Deb822 sources"
else
  fail "Azure CLI repository migration does not prevent duplicate apt sources"
fi

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

if grep -Eq "alias[[:space:]]+(ls|cat)=['\"](eza|bat)" \
  "$DOTFILES_DIR/dot_zshrc.tmpl" "$DOTFILES_DIR/dot_bashrc"; then
  fail "core commands must not be replaced by eza or bat aliases"
else
  pass "core ls and cat commands retain their standard implementations"
fi

if grep -RiqE 'gemini_cli|binary:[[:space:]]*gemini|command:[[:space:]]*gemini' \
  "$DOTFILES_DIR/packages.yaml" "$DOTFILES_DIR/packages.meta.yaml" \
  "$DOTFILES_DIR/packages.lock" "$DOTFILES_DIR/scripts/update-packages.sh" ||
  grep -Fq 'npm_install_global @google/gemini-cli' \
    "$DOTFILES_DIR/.chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl"; then
  fail "deprecated Gemini CLI references remain"
else
  pass "Gemini CLI has been removed"
fi

if grep -Fq 'ANTIGRAVITY_INSTALLER_SHA="$(package_metadata ai_tools antigravity_cli sha256)"' \
  "$DOTFILES_DIR/.chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl" &&
  grep -Fq 'https://antigravity.google/cli/install.sh' \
    "$DOTFILES_DIR/.chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl" &&
  grep -Fq 'command: agy' "$DOTFILES_DIR/agents.yaml"; then
  pass "Antigravity uses the verified official agy installer"
else
  fail "Antigravity must use the verified official agy installer"
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

if grep -Fq 'export PATH="$NODE_ROOT/bin:$PATH"' \
  "$DOTFILES_DIR/.chezmoiscripts/run_once_04-install-languages.sh.tmpl"; then
  pass "managed Node is on PATH before npm executes"
else
  fail "managed Node must be on PATH before npm executes its env-based node shebang"
fi

if grep -Fq 'managed_link "$prefix/bin/$binary" "$HOME/.local/bin/$binary"' \
  "$DOTFILES_DIR/scripts/lib.sh" &&
  grep -Fq -- '--allow-scripts=$allow_scripts' "$DOTFILES_DIR/scripts/lib.sh"; then
  pass "npm global CLIs expose stable shims with explicit install-script allowlists"
else
  fail "npm global CLIs need stable shims and explicit install-script allowlists"
fi

if grep -Fq 'managed_link "$JAVA_CURRENT/bin/$binary"' \
  "$DOTFILES_DIR/.chezmoiscripts/run_once_04-install-languages.sh.tmpl"; then
  pass "managed Java exposes stable user-local shims"
else
  fail "managed Java requires stable shims for same-run and future command discovery"
fi

if grep -Fq 'managed_link "$GO_BIN_DIR/$binary"' \
  "$DOTFILES_DIR/.chezmoiscripts/run_once_04-install-languages.sh.tmpl" &&
  grep -Fq 'managed_link "$HOME/.cargo/bin/$binary"' \
    "$DOTFILES_DIR/.chezmoiscripts/run_once_04-install-languages.sh.tmpl"; then
  pass "managed Go and Rust expose stable user-local shims"
else
  fail "managed Go and Rust require stable shims for same-run command discovery"
fi

if grep -Fq 'retry_command "Codex standalone installer" 4 5' \
  "$DOTFILES_DIR/.chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl" &&
  grep -Fq 'env CODEX_NON_INTERACTIVE=1 sh "$tmpdir/codex-install.sh"' \
    "$DOTFILES_DIR/.chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl"; then
  pass "Codex standalone installation is noninteractive and retries transient vendor failures"
else
  fail "Codex standalone installation must suppress vendor prompts and retry transient failures"
fi

AI_INSTALLER="$DOTFILES_DIR/.chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl"
if grep -Fq 'package_version ai_tools serena' "$AI_INSTALLER" &&
  grep -Fq 'uv tool install --force -p 3.13 "serena-agent==${SERENA_VERSION}"' "$AI_INSTALLER" &&
  grep -Fq 'package_version ai_tools context_mode' "$AI_INSTALLER" &&
  grep -Fq 'context-mode,better-sqlite3' "$AI_INSTALLER" &&
  grep -Fq 'package_version ai_tools graphify' "$AI_INSTALLER" &&
  grep -Fq 'uv tool install --force -p 3.13 "graphifyy==${GRAPHIFY_VERSION}"' "$AI_INSTALLER" &&
  grep -Fq 'graphify install --platform agents' "$AI_INSTALLER"; then
  pass "optional agent context tools are versioned and Graphify registers passively"
else
  fail "optional agent context tool installation contracts are incomplete"
fi

MCP_MANAGER="$DOTFILES_DIR/dot_local/bin/executable_agent-mcp"
if grep -Fq 'ALL_AGENTS=(codex claude agy opencode omp)' "$MCP_MANAGER" &&
  grep -Fq 'ALL_SERVERS=(serena context-mode)' "$MCP_MANAGER" &&
  grep -Fq 'Servers are installed but disabled until explicitly enabled.' "$MCP_MANAGER"; then
  pass "optional MCP manager covers every supported agent and defaults off"
else
  fail "optional MCP manager coverage or default-off policy is incomplete"
fi

AGENT_GUIDANCE="$DOTFILES_DIR/dot_config/agents/AGENTS.md"
if [[ "$(wc -l <"$AGENT_GUIDANCE")" -le 100 ]] &&
  grep -Fq '`fdfind` or `fd`' "$AGENT_GUIDANCE" &&
  grep -Fq '`gojq` (or `jq`)' "$AGENT_GUIDANCE" &&
  grep -Fq '`pigz`' "$AGENT_GUIDANCE" &&
  grep -Fq '`zstd`' "$AGENT_GUIDANCE"; then
  pass "global agent guidance is concise and names the managed engineering tools"
else
  fail "global agent guidance is too long or omits managed tooling"
fi

for link_spec in \
  'dot_codex/symlink_AGENTS.md:../.config/agents/AGENTS.md' \
  'dot_claude/symlink_CLAUDE.md:../.config/agents/AGENTS.md' \
  'dot_config/opencode/symlink_AGENTS.md:../agents/AGENTS.md' \
  'dot_gemini/symlink_GEMINI.md:../.config/agents/AGENTS.md' \
  'dot_omp/agent/symlink_AGENTS.md:../../.config/agents/AGENTS.md'; do
  link_path="${link_spec%%:*}"
  link_target="${link_spec#*:}"
  if [[ "$(cat "$DOTFILES_DIR/$link_path")" == "$link_target" ]]; then
    pass "$link_path targets the canonical agent guidance"
  else
    fail "$link_path has an unexpected target"
  fi
done

SSH_CONFIG="$DOTFILES_DIR/private_dot_ssh/private_config.tmpl"
if grep -Fq 'AddKeysToAgent 8h' "$SSH_CONFIG" &&
  grep -Fq 'ControlPath ~/.ssh/cm-%C' "$SSH_CONFIG" &&
  grep -Fq 'ProxyCommand %d/.local/bin/cloudflare-ssh proxy %h' "$SSH_CONFIG" &&
  grep -Fq 'PreferredAuthentications publickey' "$SSH_CONFIG" &&
  grep -Fq 'PasswordAuthentication no' "$SSH_CONFIG" &&
  grep -Fq 'KbdInteractiveAuthentication no' "$SSH_CONFIG" &&
  grep -Fq 'ConnectTimeout 15' "$SSH_CONFIG" &&
  ! grep -Eqi 'password(authentication)?[[:space:]]+yes|password[[:space:]]*=' "$SSH_CONFIG"; then
  pass "SSH persists unlocked keys only in agent memory and delegates Access transport"
else
  fail "SSH key caching or Cloudflare Access configuration is unsafe or incomplete"
fi

if grep -Fq 'prefix = "ctrl+s"' "$DOTFILES_DIR/dot_config/herdr/config.toml" &&
  grep -Fq 'set -g prefix C-s' "$DOTFILES_DIR/dot_tmux.conf.tmpl"; then
  pass "Herdr and tmux share the Ctrl+S prefix"
else
  fail "Herdr and tmux must both use Ctrl+S"
fi

if grep -Fq 'allow_nested = false' "$DOTFILES_DIR/dot_config/herdr/config.toml" &&
  grep -Fq -- '--allow-nested' "$DOTFILES_DIR/dot_local/bin/executable_dot-workspace"; then
  pass "workspace nesting is guarded and explicitly opt-in"
else
  fail "workspace nesting policy is incomplete"
fi

if grep -Fq 'dot-agent-launch --registry "$REGISTRY" "$agent"' \
  "$DOTFILES_DIR/dot_local/bin/executable_dot-workspace"; then
  pass "Herdr agent panes receive the resolved registry path"
else
  fail "Herdr agent panes can lose the registry when HOME is reset"
fi

if grep -Fq 'for integration in claude codex opencode omp; do' \
  "$DOTFILES_DIR/.chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl" &&
  grep -Fq 'herdr integration install "$integration"' \
    "$DOTFILES_DIR/.chezmoiscripts/run_once_08-install-ai-tools.sh.tmpl"; then
  pass "Herdr installs the supported agent integrations"
else
  fail "Herdr integration installation is incomplete"
fi

for preserved in \
  .bash_history .zsh_history .lesshst '.zcompdump*' .zsh_sessions/ \
  .local/share/zsh/ .cloudflared/; do
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
