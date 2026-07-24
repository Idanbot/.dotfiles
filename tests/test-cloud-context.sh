#!/usr/bin/env bash
# Verify cloud context profiles delegate to provider-native CLIs.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SYSTEM_PATH="$PATH"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
MOCK_BIN="$TMP_ROOT/bin"
CALLS="$TMP_ROOT/calls"
mkdir -p "$MOCK_BIN" "$TMP_ROOT/home"
touch "$CALLS"

make_mock() {
  local name="$1"
  shift
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "%%s\\t%%s\\n" %q "$*" >>%q\n' "$name" "$CALLS"
    printf '%s\n' "$@"
  } >"$MOCK_BIN/$name"
  chmod +x "$MOCK_BIN/$name"
}

make_mock kubectl '
case "$*" in
  "config current-context") printf "dev-cluster\n" ;;
esac'
make_mock gcloud '
case "$*" in
  *"config configurations list"*) printf "work\n" ;;
  "config get-value project") printf "project-123\n" ;;
esac'
make_mock aws '
case "$*" in
  "configure get region --profile work") printf "eu-west-1\n" ;;
  "sts get-caller-identity --query Account --output text") printf "123456789012\n" ;;
esac'
make_mock az '
case "$*" in
  "account show --query name -o tsv") printf "Engineering\n" ;;
  "account show --query id -o tsv") printf "00000000-0000-0000-0000-000000000001\n" ;;
esac'

export HOME="$TMP_ROOT/home"
export PATH="$MOCK_BIN:$SYSTEM_PATH"
export AWS_PROFILE=work
SCRIPT="$DOTFILES_DIR/dot_local/bin/executable_cloud-context"

"$SCRIPT" --save workstation >/dev/null
PROFILE="$HOME/.config/dotfiles/cloud-contexts/workstation.tsv"
[[ -f "$PROFILE" && "$(stat -c '%a' "$PROFILE")" == 600 ]]
grep -Fq $'kubectl_context\tdev-cluster' "$PROFILE"
grep -Fq $'gcloud_project\tproject-123' "$PROFILE"
grep -Fq $'aws_profile\twork' "$PROFILE"
grep -Fq $'azure_subscription\t00000000-0000-0000-0000-000000000001' "$PROFILE"
! grep -Eqi 'secret|token|password|credential' "$PROFILE"

: >"$CALLS"
"$SCRIPT" --load workstation >/dev/null
grep -Fq $'kubectl\tconfig use-context dev-cluster' "$CALLS"
grep -Fq $'gcloud\tconfig configurations activate work --quiet' "$CALLS"
grep -Fq $'gcloud\tconfig set project project-123 --quiet' "$CALLS"
grep -Fq $'az\taccount set --subscription 00000000-0000-0000-0000-000000000001' "$CALLS"
grep -Fq 'export AWS_PROFILE=work' "$HOME/.local/state/dotfiles/cloud-context.env"

: >"$CALLS"
"$SCRIPT" --clear >/dev/null
grep -Fq $'kubectl\tconfig unset current-context' "$CALLS"
grep -Fq $'gcloud\tconfig unset project --quiet' "$CALLS"
grep -Fq $'az\taccount clear' "$CALLS"
grep -Fq 'unset AWS_PROFILE' "$HOME/.local/state/dotfiles/cloud-context.env"

[[ "$("$SCRIPT" prompt aws)" == 123456789012 ]]
[[ "$("$SCRIPT" --list)" == workstation ]]

grep -Fq '$custom.aws_account' "$DOTFILES_DIR/dot_config/starship.toml"
grep -Fq '$azure' "$DOTFILES_DIR/dot_config/starship.toml"
grep -Fq 'command cloud-context "$@"' "$DOTFILES_DIR/dot_zshrc.tmpl"

printf 'Cloud context test passed\n'
