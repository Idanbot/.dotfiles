#!/usr/bin/env bash
# Execute real installer blocks with offline fixtures: no downloads or defaults changed.
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
export HOME="$temporary/home" DOTFILES_SOURCE_DIR="$ROOT"
export DOTFILES_STATE_DIR="$HOME/state" DOTFILES_VERSION_PLAN="$temporary/versions.json"
mkdir -p "$HOME/.local/bin" "$HOME/external/bin"
printf '{"tools":{}}\n' >"$DOTFILES_VERSION_PLAN"
source "$ROOT/scripts/lib.sh"
download_verified() { printf 'Unexpected download\n' >&2; return 99; }
require_sudo() { :; }
rustup() { printf 'Unexpected rustup mutation\n' >&2; return 99; }
managed_link() { printf 'Unexpected shim replacement\n' >&2; return 99; }
for binary in go gofmt rustc cargo node npm npx java javac tsc uv uvx; do
  printf '#!/bin/sh\nprintf "%%s\\n" "99.99.99"\n' >"$HOME/external/bin/$binary"
  chmod +x "$HOME/external/bin/$binary"
done
export PATH="$HOME/external/bin:$PATH"

for spec in 'GO_VERSION=:RUST_CHANNEL=' 'RUST_CHANNEL=:NODE_VERSION=' 'NODE_VERSION=:TYPESCRIPT_VERSION=' 'JAVA_VERSION=:print_summary'; do
  start="${spec%%:*}" end="${spec#*:}"
  awk -v start="$start" -v end="$end" '
    index($0, start) == 1 {block = 1}
    index($0, end) == 1 {exit}
    block
  ' "$ROOT/.chezmoiscripts/run_once_04-install-languages.sh.tmpl" >"$temporary/block.sh"
  source "$temporary/block.sh"
done
[[ "$(node --version)" == 99.99.99 && "$(npm --version)" == 99.99.99 ]]
[[ "$(command -v java)" == "$HOME/external/bin/java" ]]
[[ ! -e "$HOME/.local/share/dotfiles/tools/java/current" ]]
[[ ! -e "$DOTFILES_STATE_DIR/installed.tsv" ]]
runtime_is_current node 26.11.1 'v99.99.99' >"$temporary/newer.log"
grep -Fq 'newer than repository' "$temporary/newer.log"

# An older external executable elsewhere on PATH must not be shadowed.
printf '#!/bin/sh\necho 1.0.0\n' >"$HOME/external/bin/helm"
chmod +x "$HOME/external/bin/helm"
preserve_existing_release_binary helm 1.0.0 >"$temporary/preserve.log"
grep -Fq 'unowned or modified' "$temporary/preserve.log"
[[ ! -e "$HOME/.local/bin/helm" ]]

# A previously managed npm newer than the pin also stays untouched.
NODE_ROOT="$HOME/external"
NODE_VERSION=99.99.99
export NODE_ROOT NODE_VERSION
awk '/^NPM_VERSION=/ {block = 1} /^for binary in node / {exit} block' \
  "$ROOT/.chezmoiscripts/run_once_04-install-languages.sh.tmpl" >"$temporary/npm.sh"
source "$temporary/npm.sh"
[[ "$(npm --version)" == 99.99.99 ]]

# APT may update only a package-owned command, and only the frozen upstream version.
unset -f managed_link
version_plan_value() { printf '2.9.0\n'; }
dpkg-query() { printf 'azure-cli: %s\n' "$HOME/external/bin/az"; }
apt-cache() { printf 'azure-cli | 3.0.0-1~noble | repo\nazure-cli | 2.9.0-2~noble | repo\n'; }
sudo() { printf '%s\n' "$*" >>"$temporary/apt-calls"; }
printf '#!/bin/sh\necho 2.1.0\n' >"$HOME/external/bin/az"
chmod +x "$HOME/external/bin/az"
install_policy_apt az azure-cli cloud.azure_cli 2.1.0
grep -Fxq 'apt-get install -y azure-cli=2.9.0-2~noble' "$temporary/apt-calls"
rm "$temporary/apt-calls"
install_policy_apt az azure-cli cloud.azure_cli 3.0.0
[[ ! -e "$temporary/apt-calls" ]]
dpkg-query() { return 1; }
install_policy_apt az azure-cli cloud.azure_cli 2.1.0
[[ ! -e "$temporary/apt-calls" ]]
dpkg-query() { printf 'azure-cli: /fake\n'; }
apt-cache() { printf 'azure-cli | 3.0.0-1~noble | repo\n'; }
if install_policy_apt az azure-cli cloud.azure_cli 2.1.0; then
  printf 'APT silently crossed the major boundary\n' >&2
  exit 1
fi
[[ ! -e "$temporary/apt-calls" ]]

# Real AWS verifier rejects signature failures and accepts only the pinned key.
unset -f download_verified
mkdir -m 700 "$temporary/keyring"
gpg --batch --homedir "$temporary/keyring" --show-keys --with-colons "$ROOT/scripts/keys/aws-cli.asc" |
  grep -Fq FB5DB77FD5C118B80511ADA8A6310ACC4672475C
download() { printf 'payload\n' >"$2"; }
gpg() {
  case "$*" in
    *--fingerprint*) printf 'fpr:::::::::FB5DB77FD5C118B80511ADA8A6310ACC4672475C:\n' ;;
    *--verify*) return "${AWS_VERIFY_STATUS:-0}" ;;
  esac
}
if AWS_VERIFY_STATUS=1 download_aws_signed https://awscli.amazonaws.com/fixture.zip "$temporary/aws.zip"; then
  printf 'Bad AWS signature accepted\n' >&2
  exit 1
fi
[[ ! -e "$temporary/aws.zip" ]]
download_aws_signed https://awscli.amazonaws.com/fixture.zip "$temporary/aws.zip"
[[ -s "$temporary/aws.zip" && -s "${DOTFILES_VERSION_PLAN%.json}-aws.sha256" ]]
gpg() { printf 'fpr:::::::::0000000000000000000000000000000000000000:\n'; }
if download_aws_signed https://awscli.amazonaws.com/fixture.zip "$temporary/wrong-key.zip"; then
  printf 'Wrong AWS signing key accepted\n' >&2
  exit 1
fi
[[ ! -e "$temporary/wrong-key.zip" ]]

printf 'Runtime preservation, signed downloads, and APT major-boundary tests passed\n'
