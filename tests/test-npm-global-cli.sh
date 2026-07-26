#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export DOTFILES_SOURCE_DIR="$DOTFILES_DIR"
export DOTFILES_STATE_DIR="$HOME/.local/state/dotfiles"
export DOTFILES_NPM_PREFIX="$HOME/.local/share/npm"
mkdir -p "$DOTFILES_NPM_PREFIX/bin" "$HOME/.local/bin" "$HOME/test-bin"

# shellcheck source=scripts/lib.sh
source "$DOTFILES_DIR/scripts/lib.sh"

cat >"$DOTFILES_NPM_PREFIX/bin/existing-cli" <<'EOF'
#!/usr/bin/env bash
printf 'existing-cli 2.0.0\n'
EOF
chmod +x "$DOTFILES_NPM_PREFIX/bin/existing-cli"

npm_install_global existing-package 1.0.0 existing-cli
[[ "$(readlink "$HOME/.local/bin/existing-cli")" == "$DOTFILES_NPM_PREFIX/bin/existing-cli" ]]

cat >"$HOME/test-bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$HOME/npm-args"
cat >"$DOTFILES_NPM_PREFIX/bin/scripted-cli" <<'SCRIPT'
#!/usr/bin/env bash
printf 'scripted-cli 3.0.0\n'
SCRIPT
chmod +x "$DOTFILES_NPM_PREFIX/bin/scripted-cli"
EOF
chmod +x "$HOME/test-bin/npm"
export PATH="$HOME/test-bin:$PATH"

npm_install_global scripted-package 3.0.0 scripted-cli scripted-package
grep -Fq -- '--allow-scripts=scripted-package' "$HOME/npm-args"
grep -Fq 'scripted-package@3.0.0' "$HOME/npm-args"
[[ "$(readlink "$HOME/.local/bin/scripted-cli")" == "$DOTFILES_NPM_PREFIX/bin/scripted-cli" ]]
"$HOME/.local/bin/scripted-cli" --version | grep -Fq '3.0.0'

printf 'npm global CLI test passed\n'
