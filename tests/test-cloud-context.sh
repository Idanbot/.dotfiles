#!/usr/bin/env bash
# Verify cloud context profiles delegate to provider-native CLIs.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SYSTEM_BASH="$(command -v bash)"
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
  "config current-context") printf "lab\n" ;;
  "config get-contexts lab -o name") printf "lab\n" ;;
  "config view --minify --output jsonpath={..namespace}") printf "team-a\n" ;;
esac'
make_mock gcloud '
case "$*" in
  *"config configurations list"*) printf "work\n" ;;
  "config get-value project") printf "project-123\n" ;;
  "config configurations describe work --format=value(name)") printf "work\n" ;;
esac'
make_mock aws '
case "$*" in
  "configure get region --profile work") printf "eu-west-1\n" ;;
  "configure list-profiles") printf "work\n" ;;
  "sts get-caller-identity --query Account --output text") printf "123456789012\n" ;;
esac'
make_mock az '
case "$*" in
  "account show --query name -o tsv") printf "Engineering\n" ;;
  "account show --query id -o tsv") printf "00000000-0000-0000-0000-000000000001\n" ;;
  "account list --query [?id=='\''00000000-0000-0000-0000-000000000001'\''].id -o tsv") printf "00000000-0000-0000-0000-000000000001\n" ;;
esac'

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export PATH="$MOCK_BIN:/usr/bin:/bin"
unset AWS_DEFAULT_PROFILE AWS_DEFAULT_REGION AWS_REGION
export AWS_PROFILE=work
SCRIPT="$DOTFILES_DIR/dot_local/bin/executable_cloud-context"

"$SCRIPT" --save workstation >/dev/null
PROFILE="$HOME/.config/dotfiles/cloud-contexts/workstation.tsv"
[[ -f "$PROFILE" && "$(stat -c '%a' "$PROFILE")" == 600 ]]
grep -Fq $'kubectl_context\tlab' "$PROFILE"
grep -Fq $'gcloud_project\tproject-123' "$PROFILE"
grep -Fq $'aws_profile\twork' "$PROFILE"
grep -Fq $'azure_subscription\t00000000-0000-0000-0000-000000000001' "$PROFILE"
! grep -Eqi 'secret|token|password|credential' "$PROFILE"

: >"$CALLS"
"$SCRIPT" --load workstation >/dev/null
grep -Fq $'kubectl\tconfig use-context lab' "$CALLS"
grep -Fq $'gcloud\tconfig configurations activate work --quiet' "$CALLS"
grep -Fq $'gcloud\tconfig set project project-123 --quiet' "$CALLS"
grep -Fq $'az\taccount set --subscription 00000000-0000-0000-0000-000000000001' "$CALLS"
grep -Fq 'export AWS_PROFILE=work' "$HOME/.local/state/dotfiles/cloud-context.env"

: >"$CALLS"
"$SCRIPT" --clear >/dev/null
[[ "$(stat -c '%a' "$XDG_STATE_HOME/dotfiles")" == 700 ]]
grep -Fq $'kubectl\tconfig unset current-context' "$CALLS"
grep -Fq $'gcloud\tconfig unset project --quiet' "$CALLS"
grep -Fq $'az\taccount clear' "$CALLS"
grep -Fq 'unset AWS_PROFILE' "$HOME/.local/state/dotfiles/cloud-context.env"

[[ "$("$SCRIPT" prompt aws)" == 123456789012 ]]
[[ "$("$SCRIPT" prompt kubectl)" == 'lab (team-a)' ]]
long_context=organization-production-europe-west1-primary-cluster
make_mock kubectl "
case \"\$*\" in
  \"config current-context\") printf '%s\\n' '$long_context' ;;
esac"
short_context="$("$SCRIPT" prompt kubectl)"
[[ "${#short_context}" -le 28 ]]
[[ "$short_context" == *...* ]]
[[ "$short_context" != "$long_context" ]]
[[ "$("$SCRIPT" --list)" == workstation ]]

for provider in kubectl gcloud aws azure; do
  "$SCRIPT" --test-clear >/dev/null
  "$SCRIPT" --test "$provider" >/dev/null
  [[ -e "$XDG_STATE_HOME/dotfiles/cloud-context-test/enabled-$provider" ]]
  [[ "$(find "$XDG_STATE_HOME/dotfiles/cloud-context-test" \
    -maxdepth 1 -name 'enabled-*' | wc -l)" == 1 ]]
done
"$SCRIPT" --test all >/dev/null
for provider in kubectl gcloud aws azure; do
  [[ -e "$XDG_STATE_HOME/dotfiles/cloud-context-test/enabled-$provider" ]]
done
grep -Fq 'current-context: cloud-context-test' \
  "$XDG_STATE_HOME/dotfiles/cloud-context-test/kube/config"
grep -Fq 'export KUBECONFIG=' \
  "$XDG_STATE_HOME/dotfiles/cloud-context-test.env"
rm -f "$XDG_STATE_HOME/dotfiles/cloud-context-aws.cache"
[[ "$(CLOUD_CONTEXT_TEST_AWS_ACCOUNT=000000000042 "$SCRIPT" prompt aws)" == 000000000042 ]]
"$SCRIPT" --test-clear aws >/dev/null
[[ ! -e "$XDG_STATE_HOME/dotfiles/cloud-context-test/enabled-aws" ]]
"$SCRIPT" --test-clear >/dev/null
[[ ! -e "$XDG_STATE_HOME/dotfiles/cloud-context-test/active" ]]
! find "$XDG_STATE_HOME/dotfiles/cloud-context-test" \
  -maxdepth 1 -name 'enabled-*' -print -quit | grep -q .

cp "$PROFILE" "${PROFILE%/*}/missing.tsv"
sed -i \
  -e 's/\tlab$/\tmissing-cluster/' \
  -e 's/\twork$/\tmissing/' \
  -e 's/00000000-0000-0000-0000-000000000001/ffffffff-ffff-ffff-ffff-ffffffffffff/' \
  "${PROFILE%/*}/missing.tsv"
: >"$CALLS"
if "$SCRIPT" --load missing >/dev/null 2>&1; then
  echo "Nonexistent contexts were accepted" >&2
  exit 1
fi
! grep -Eq 'use-context|configurations activate|account set' "$CALLS"

mv "$MOCK_BIN/kubectl" "$MOCK_BIN/kubectl.disabled"
if PATH="$MOCK_BIN" "$SYSTEM_BASH" "$SCRIPT" --clear kubectl >/dev/null 2>&1; then
  echo "Clearing an unavailable provider reported success" >&2
  exit 1
fi

grep -Fq '${custom.aws_account}' "$DOTFILES_DIR/dot_config/starship.toml"
grep -Fq '${custom.kubernetes_context}' "$DOTFILES_DIR/dot_config/starship.toml"
grep -Fq '$azure' "$DOTFILES_DIR/dot_config/starship.toml"
grep -Fq 'command cloud-context "$@"' "$DOTFILES_DIR/dot_zshrc.tmpl"

printf 'Cloud context test passed\n'
