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
  "config current-context")
    if [[ "${KUBECONFIG:-}" == *cloud-context-test* ]]; then
      printf "cloud-context-test\n"
    else
      printf "lab\n"
    fi
    ;;
  "config get-contexts lab -o name") printf "lab\n" ;;
  "config view --minify --output jsonpath={..namespace}")
    if [[ "${KUBECONFIG:-}" == *cloud-context-test* ]]; then
      printf "test\n"
    else
      printf "team-a\n"
    fi
    ;;
esac'
make_mock gcloud '
case "$*" in
  "auth list --filter=status:ACTIVE --format=value(account)")
    [[ "${GCLOUD_NO_ACTIVE:-0}" == 1 ]] || printf "user@example.invalid\n"
    ;;
  *"config configurations list"*)
    [[ "${CLOUDSDK_CONFIG:-}" == *cloud-context-test* ]] &&
      printf "test\n" || printf "work\n"
    ;;
  "config get-value project")
    if [[ "${CLOUDSDK_CONFIG:-}" == *cloud-context-test* ]]; then
      printf "cloud-context-test\n"
    elif [[ "${GCLOUD_PROJECT_UNSET:-0}" == 1 ]]; then
      printf "(unset)\n"
    else
      printf "project-123\n"
    fi
    ;;
  "projects list --filter=lifecycleState:ACTIVE --format=value(projectId) --quiet")
    [[ "${GCLOUD_PROJECTS_DELAY:-0}" == 0 ]] || sleep "$GCLOUD_PROJECTS_DELAY"
    [[ "${GCLOUD_PROJECTS_EMPTY:-0}" == 1 ]] ||
      printf "project-123\nproject-456\n"
    ;;
  "config configurations describe work --format=value(name)") printf "work\n" ;;
esac'
make_mock aws '
case "$*" in
  "configure get region --profile work") printf "eu-west-1\n" ;;
  "configure get region --profile personal") printf "us-east-2\n" ;;
  "configure list-profiles")
    printf "work\npersonal\n"
    for i in $(seq 1 10000); do
      printf "profile-%s\n" "$i"
    done
    ;;
  "sts get-caller-identity --query Account --output text") printf "%s\n" "${MOCK_ACCOUNT:-123456789012}" ;;
esac'
make_mock az '
case "$*" in
  "account show --query name -o tsv")
    [[ "${AZURE_CONFIG_DIR:-}" == *cloud-context-test* ]] &&
      printf "Cloud Context Test\n" || printf "Engineering\n"
    ;;
  "account show --query id -o tsv")
    [[ "${AZURE_CONFIG_DIR:-}" == *cloud-context-test* ]] &&
      printf "00000000-0000-0000-0000-000000000042\n" ||
      printf "00000000-0000-0000-0000-000000000001\n"
    ;;
  "account list --query [].[id,name] -o tsv") printf "00000000-0000-0000-0000-000000000001\tEngineering\n00000000-0000-0000-0000-000000000002\tSandbox\n" ;;
  "account list --query [?id=='\''00000000-0000-0000-0000-000000000001'\''].id -o tsv") printf "00000000-0000-0000-0000-000000000001\n" ;;
esac'
make_mock fzf '
input="$(cat)"
[[ -z "${FZF_INPUT:-}" ]] || printf "%s\n" "$input" >"$FZF_INPUT"
if [[ -n "${FZF_PICK:-}" ]]; then
  grep -Fx -- "$FZF_PICK" <<<"$input" | head -n 1
else
  head -n 1 <<<"$input"
fi'

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
if find "$HOME/.config/dotfiles/cloud-contexts" -type f \
  -exec grep -Eqi 'secret|token|password|credential|private[_-]?key|access[_-]?token' {} \; \
  -print -quit | grep -q .; then
  printf 'Cloud context artifacts contain credential-like data\n' >&2
  exit 1
fi
for forbidden in \
  "$HOME/.aws/credentials" \
  "$HOME/.azure/accessTokens.json" \
  "$HOME/.config/gcloud/credentials.db"; do
  [[ ! -e "$forbidden" ]] || {
    printf 'Cloud context test created a credential file: %s\n' "$forbidden" >&2
    exit 1
  }
done

: >"$CALLS"
"$SCRIPT" --load workstation >/dev/null
grep -Fq $'kubectl\tconfig use-context lab' "$CALLS"
grep -Fq $'gcloud\tconfig configurations activate work --quiet' "$CALLS"
grep -Fq $'gcloud\tconfig set project project-123 --quiet' "$CALLS"
grep -Fq $'az\taccount set --subscription 00000000-0000-0000-0000-000000000001' "$CALLS"
grep -Fq 'export AWS_PROFILE=work' "$HOME/.local/state/dotfiles/cloud-context.env"

: >"$CALLS"
FZF_PICK=project-456 "$SCRIPT" --select gcloud >/dev/null
grep -Fq $'gcloud\tconfig set project project-456 --quiet' "$CALLS"
[[ "$(<"$XDG_CONFIG_HOME/dotfiles/cloud-contexts/.recent-selections/gcloud")" == project-456 ]]

: >"$CALLS"
FZF_PICK=personal "$SCRIPT" --select aws >/dev/null
grep -Fq $'aws\tconfigure get region --profile personal' "$CALLS"
grep -Fq 'export AWS_PROFILE=personal' "$HOME/.local/state/dotfiles/cloud-context.env"
grep -Fq 'export AWS_DEFAULT_REGION=us-east-2' "$HOME/.local/state/dotfiles/cloud-context.env"
[[ "$(<"$XDG_CONFIG_HOME/dotfiles/cloud-contexts/.recent-selections/aws")" == personal ]]

: >"$CALLS"
FZF_PICK=$'00000000-0000-0000-0000-000000000002\tSandbox' \
  "$SCRIPT" --select azure >/dev/null
grep -Fq $'az\taccount set --subscription 00000000-0000-0000-0000-000000000002' "$CALLS"
[[ "$(<"$XDG_CONFIG_HOME/dotfiles/cloud-contexts/.recent-selections/azure")" == 00000000-0000-0000-0000-000000000002 ]]

FZF_INPUT="$TMP_ROOT/gcloud-fzf-input" "$SCRIPT" --select gcloud >/dev/null
[[ "$(<"$TMP_ROOT/gcloud-fzf-input")" == $'project-456\nproject-123' ]]
FZF_INPUT="$TMP_ROOT/azure-fzf-input" "$SCRIPT" --select azure >/dev/null
[[ "$(<"$TMP_ROOT/azure-fzf-input")" == $'00000000-0000-0000-0000-000000000002\tSandbox\n00000000-0000-0000-0000-000000000001\tEngineering' ]]

: >"$CALLS"
if GCLOUD_NO_ACTIVE=1 "$SCRIPT" --select gcloud >"$TMP_ROOT/no-account.out" 2>&1; then
  echo "GCloud selection succeeded without an active account" >&2
  exit 1
fi
grep -Fq 'No active GCloud account' "$TMP_ROOT/no-account.out"
! grep -Fq $'fzf\t' "$CALLS"

: >"$CALLS"
if GCLOUD_PROJECT_UNSET=1 GCLOUD_PROJECTS_EMPTY=1 \
  "$SCRIPT" --select gcloud >"$TMP_ROOT/no-projects.out" 2>&1; then
  echo "GCloud selection succeeded without accessible projects" >&2
  exit 1
fi
grep -Fq 'No accessible GCloud projects' "$TMP_ROOT/no-projects.out"
! grep -Fq $'fzf\t' "$CALLS"

: >"$CALLS"
if CLOUD_CONTEXT_DISCOVERY_TIMEOUT=1 GCLOUD_PROJECTS_DELAY=2 \
  "$SCRIPT" --select gcloud >"$TMP_ROOT/projects-timeout.out" 2>&1; then
  echo "GCloud selection succeeded after project discovery timed out" >&2
  exit 1
fi
grep -Fq 'GCloud project discovery timed out' "$TMP_ROOT/projects-timeout.out"
! grep -Fq $'fzf\t' "$CALLS"

: >"$CALLS"
"$SCRIPT" --clear >/dev/null
[[ "$(stat -c '%a' "$XDG_STATE_HOME/dotfiles")" == 700 ]]
grep -Fq $'kubectl\tconfig unset current-context' "$CALLS"
grep -Fq $'gcloud\tconfig unset project --quiet' "$CALLS"
grep -Fq $'az\taccount clear' "$CALLS"
grep -Fq 'unset AWS_PROFILE' "$HOME/.local/state/dotfiles/cloud-context.env"
recent_root="$XDG_CONFIG_HOME/dotfiles/cloud-contexts/.recent-profiles"
[[ "$(find "$recent_root" -maxdepth 1 -type f -name '*.tsv' | wc -l)" == 1 ]]

for day in 01 02 03 04 05 06; do
  CLOUD_CONTEXT_TIMESTAMP="203001${day}-010203" "$SCRIPT" --clear aws >/dev/null
done
[[ "$(find "$recent_root" -maxdepth 1 -type f -name '*.tsv' | wc -l)" == 5 ]]
[[ ! -e "$recent_root/20300101-010203.tsv" ]]
[[ -e "$recent_root/20300106-010203.tsv" ]]

: >"$CALLS"
FZF_PICK=20300106-010203 "$SCRIPT" --recent >/dev/null
grep -Fq $'kubectl\tconfig use-context lab' "$CALLS"
grep -Fq $'gcloud\tconfig set project project-123 --quiet' "$CALLS"
grep -Fq 'export AWS_PROFILE=work' "$HOME/.local/state/dotfiles/cloud-context.env"

[[ "$("$SCRIPT" prompt aws)" == 123456789012 ]]
export AWS_ACCESS_KEY_ID=synthetic-key-one
[[ "$(MOCK_ACCOUNT=111111111111 "$SCRIPT" prompt aws)" == 111111111111 ]]
export AWS_ACCESS_KEY_ID=synthetic-key-two
[[ "$(MOCK_ACCOUNT=222222222222 "$SCRIPT" prompt aws)" == 222222222222 ]]
[[ "$(MOCK_ACCOUNT=333333333333 "$SCRIPT" prompt aws --refresh)" == 333333333333 ]]
export AWS_CONFIG_FILE="$TMP_ROOT/aws-config"
printf '[default]\nregion=eu-west-1\n' >"$AWS_CONFIG_FILE"
[[ "$(MOCK_ACCOUNT=444444444444 "$SCRIPT" prompt aws)" == 444444444444 ]]
printf '[default]\nregion=us-east-1\n' >"$AWS_CONFIG_FILE"
[[ "$(MOCK_ACCOUNT=555555555555 "$SCRIPT" prompt aws)" == 555555555555 ]]
export AWS_SHARED_CREDENTIALS_FILE="$TMP_ROOT/aws-credentials"
printf 'synthetic-one\n' >"$AWS_SHARED_CREDENTIALS_FILE"
[[ "$(MOCK_ACCOUNT=666666666666 "$SCRIPT" prompt aws)" == 666666666666 ]]
printf 'synthetic-two\n' >"$AWS_SHARED_CREDENTIALS_FILE"
[[ "$(MOCK_ACCOUNT=777777777777 "$SCRIPT" prompt aws)" == 777777777777 ]]
! grep -Rq 'synthetic-' "$XDG_STATE_HOME/dotfiles"
unset AWS_ACCESS_KEY_ID AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
AWS_REGION=us-west-2 AWS_DEFAULT_REGION=eu-west-3 "$SCRIPT" --save region-test >/dev/null
grep -Fq $'aws_region\tus-west-2' "${PROFILE%/*}/region-test.tsv"
rm "${PROFILE%/*}/region-test.tsv"
"$SCRIPT" --load workstation >/dev/null
(
  export AWS_REGION=us-west-2
  source "$XDG_STATE_HOME/dotfiles/cloud-context.env"
  [[ "$AWS_REGION" == eu-west-1 && "$AWS_DEFAULT_REGION" == eu-west-1 ]]
)
[[ "$("$SCRIPT" prompt kubectl)" == 'lab (team-a)' ]]
long_context=organization-production-europe-west1-primary-cluster
make_mock kubectl "
case \"\$*\" in
  \"config current-context\")
    if [[ \"\${KUBECONFIG:-}\" == *cloud-context-test* ]]; then
      printf 'cloud-context-test\\n'
    else
      printf '%s\\n' '$long_context'
    fi
    ;;
  \"config view --minify --output jsonpath={..namespace}\")
    [[ \"\${KUBECONFIG:-}\" == *cloud-context-test* ]] && printf 'test\\n'
    ;;
esac"
short_context="$("$SCRIPT" prompt kubectl)"
expected_short="..${long_context: -26}"
[[ "$short_context" == "$expected_short" ]]
[[ "${#short_context}" -eq 28 ]]
[[ "$("$SCRIPT" --list)" == workstation ]]

if AWS_ACCESS_KEY_ID=credential-sentinel-do-not-leak XDG_STATE_HOME="$TMP_ROOT/pristine" \
  "$SCRIPT" --test aws --yes >"$TMP_ROOT/pristine-rejection" 2>&1; then
  echo 'Fresh fake AWS accepted credentials' >&2
  exit 1
fi
[[ ! -e "$TMP_ROOT/pristine" ]]
! grep -Fq 'credential-sentinel-do-not-leak' "$TMP_ROOT/pristine-rejection" || exit 1
"$SCRIPT" --test aws --yes >/dev/null
cp -a "$HOME" "$TMP_ROOT/before-rejection"
for variable in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN \
  AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
  AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN \
  AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE GOOGLE_APPLICATION_CREDENTIALS \
  GOOGLE_OAUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
  CLOUDSDK_AUTH_ACCESS_TOKEN_FILE CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
  AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_CLIENT_CERTIFICATE_PATH AZURE_FEDERATED_TOKEN_FILE \
  AZURE_USERNAME AZURE_PASSWORD AZURE_ACCESS_TOKEN; do
  if env "$variable=credential-sentinel-do-not-leak" "$SCRIPT" --test all --yes \
    >"$TMP_ROOT/rejection" 2>&1; then
    printf 'Accepted credential override: %s\n' "$variable" >&2
    exit 1
  fi
  grep -Fq "$variable" "$TMP_ROOT/rejection"
  ! grep -Rq 'credential-sentinel-do-not-leak' "$HOME" "$TMP_ROOT/rejection" || exit 1
  diff -r "$TMP_ROOT/before-rejection" "$HOME"
done
if "$SCRIPT" --test gcloud </dev/null >/dev/null 2>&1; then
  echo "Non-interactive test reset proceeded without --yes" >&2
  exit 1
fi
[[ -e "$XDG_STATE_HOME/dotfiles/cloud-context-test/enabled-aws" ]]
[[ ! -e "$XDG_STATE_HOME/dotfiles/cloud-context-test/enabled-gcloud" ]]
python3 - "$SCRIPT" <<'PY'
import os
import pty
import subprocess
import sys

for answer, succeeds in [(b"n\n", False), (b"yes\n", True)]:
    master, slave = pty.openpty()
    try:
        process = subprocess.Popen(
            [sys.argv[1], "--test", "gcloud"], stdin=slave,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        os.write(master, answer)
        stdout, stderr = process.communicate(timeout=10)
        assert b"[y/N]" in stderr, (stdout, stderr)
        assert (process.returncode == 0) == succeeds, (stdout, stderr)
    finally:
        os.close(master)
        os.close(slave)
PY
[[ -e "$XDG_STATE_HOME/dotfiles/cloud-context-test/enabled-gcloud" ]]

for provider in kubectl gcloud aws azure; do
  "$SCRIPT" --test "$provider" --yes >/dev/null
  [[ -e "$XDG_STATE_HOME/dotfiles/cloud-context-test/enabled-$provider" ]]
  [[ "$(find "$XDG_STATE_HOME/dotfiles/cloud-context-test" \
    -maxdepth 1 -name 'enabled-*' | wc -l)" == 1 ]]
done
"$SCRIPT" --test --yes >/dev/null
for provider in kubectl gcloud aws azure; do
  [[ -e "$XDG_STATE_HOME/dotfiles/cloud-context-test/enabled-$provider" ]]
done
(
  # shellcheck disable=SC1090
  source "$XDG_STATE_HOME/dotfiles/cloud-context-test.env"
  test_status="$("$SCRIPT" --status)"
  grep -Fq 'kubectl  cloud-context-test' <<<"$test_status"
  grep -Fq 'gcloud   cloud-context-test (config: test)' <<<"$test_status"
  grep -Fq 'aws      000000000042 (profile: cloud-context-test' <<<"$test_status"
  grep -Fq 'azure    Cloud Context Test' <<<"$test_status"
)
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
grep -Fq 'command cloud-context --status' "$DOTFILES_DIR/dot_zshrc.tmpl"

mv "$MOCK_BIN/kubectl.disabled" "$MOCK_BIN/kubectl"
make_mock kubectl '
case "$*" in
  "config current-context" | "config get-contexts lab -o name") printf "lab\n" ;;
  "config view --minify --output jsonpath={..namespace}") printf "team-a\n" ;;
esac'

# A requested handoff belongs only to this invocation, never the shared files.
(
  export XDG_STATE_HOME="$TMP_ROOT/handoff-state"
  state_root="$XDG_STATE_HOME/dotfiles"
  mkdir -p "$state_root" "$TMP_ROOT/handoffs"
  printf 'export AWS_PROFILE=stale-shared\n' >"$state_root/cloud-context.env"
  shared_before="$(sha256sum "$state_root/cloud-context.env")"
  output="$TMP_ROOT/handoffs/current.env"
  CLOUD_CONTEXT_ENV_OUTPUT="$output" "$SCRIPT" --load workstation >/dev/null
  [[ -s "$output" && "$(stat -c '%a' "$output")" == 600 ]]
  grep -Fq 'export AWS_PROFILE=work' "$output"
  [[ "$(sha256sum "$state_root/cloud-context.env")" == "$shared_before" ]]
  rm "$output"
  CLOUD_CONTEXT_ENV_OUTPUT="$output" "$SCRIPT" --test all --yes >/dev/null
  [[ -s "$output" && ! -e "$state_root/cloud-context-test.env" ]]
  grep -Fq 'export CLOUD_CONTEXT_TEST_AWS_ACCOUNT=000000000042' "$output"
  rm "$output"
  CLOUD_CONTEXT_ENV_OUTPUT="$output" "$SCRIPT" --test-clear >/dev/null
  [[ -s "$output" ]]
  grep -Fq 'unset CLOUD_CONTEXT_TEST_AWS_ACCOUNT' "$output"
  rm "$output"
  rm -rf "$state_root/cloud-context-test"
  CLOUD_CONTEXT_ENV_OUTPUT="$output" "$SCRIPT" --test-clear >/dev/null
  [[ ! -e "$output" ]]
  CLOUD_CONTEXT_ENV_OUTPUT="$output" "$SCRIPT" --help >/dev/null
  [[ ! -e "$output" ]]
  if CLOUD_CONTEXT_ENV_OUTPUT="$output" "$SCRIPT" --test aws </dev/null >/dev/null 2>&1; then
    printf 'Unconfirmed fixture change succeeded\n' >&2
    exit 1
  fi
  [[ ! -e "$output" ]]
)

sed -n '/^_cloud_context_source_env() {/,/^alias cctx=/p' \
  "$DOTFILES_DIR/dot_zshrc.tmpl" >"$TMP_ROOT/wrapper.zsh"
ln -s "$SCRIPT" "$MOCK_BIN/cloud-context"
mkdir -p "$TMP_ROOT/no-handoff"
printf '#!/bin/sh\nexit 0\n' >"$TMP_ROOT/no-handoff/cloud-context"
chmod +x "$TMP_ROOT/no-handoff/cloud-context"
wrapper_failures=0
for scenario in startup read-only provider-only failed no-handoff-aws no-handoff-test successful fixtures; do
  wrapper_home="$TMP_ROOT/wrapper-$scenario"
  mkdir -p "$wrapper_home/.config/dotfiles/cloud-contexts"
  cp "$PROFILE" "$wrapper_home/.config/dotfiles/cloud-contexts/workstation.tsv"
  if ! HOME="$wrapper_home" XDG_CONFIG_HOME="$wrapper_home/.config" \
    XDG_STATE_HOME="$wrapper_home/.local/state" \
    zsh -f -s -- "$TMP_ROOT/wrapper.zsh" "$scenario" "$TMP_ROOT/no-handoff" <<'ZSH'; then
set -eu
export AWS_PROFILE=work AWS_DEFAULT_PROFILE=work-default
export AWS_REGION=eu-west-1 AWS_DEFAULT_REGION=eu-west-1
# Another terminal writes the shared handoff without changing this shell.
FZF_PICK=personal command cloud-context --select aws >/dev/null
if [[ "$2" == startup ]]; then
  source "$1"
  [[ "$AWS_PROFILE" == work && "$AWS_REGION" == eu-west-1 ]]
  exit
fi
source "$1"
export AWS_PROFILE=work AWS_DEFAULT_PROFILE=work-default
export AWS_REGION=eu-west-1 AWS_DEFAULT_REGION=eu-west-1
assert_original_aws() {
  [[ "$AWS_PROFILE" == work && "$AWS_DEFAULT_PROFILE" == work-default &&
    "$AWS_REGION" == eu-west-1 && "$AWS_DEFAULT_REGION" == eu-west-1 ]]
}
case "$2" in
  read-only)
    for option in --help help --status status --list list ''; do
      if [[ -n "$option" ]]; then
        cloud-context "$option" >/dev/null
      else
        cloud-context >/dev/null
      fi
      assert_original_aws
    done
    cloud-context prompt aws >/dev/null
    assert_original_aws
    cloud-context --save unchanged >/dev/null
    assert_original_aws
    ;;
  provider-only)
    FZF_PICK=project-456 cloud-context --select gcloud >/dev/null
    assert_original_aws
    cloud-context --clear gcloud >/dev/null
    assert_original_aws
    cloud-context --test-clear >/dev/null
    assert_original_aws
    ;;
  failed)
    cloud-context --load missing >/dev/null 2>&1 && exit 1
    [[ $? == 1 ]]
    assert_original_aws
    FZF_PICK=missing cloud-context --select aws >/dev/null 2>&1 && exit 1
    assert_original_aws
    cloud-context --unknown >/dev/null 2>&1 && exit 1
    [[ $? == 2 ]]
    assert_original_aws
    ;;
  no-handoff-aws | no-handoff-test)
    export PATH="$3:$PATH"
    if [[ "$2" == no-handoff-aws ]]; then
      cloud-context --recent >/dev/null
    else
      printf 'export AWS_PROFILE=stale-fixture\n' >"$XDG_STATE_HOME/dotfiles/cloud-context-test.env"
      cloud-context --test aws --yes >/dev/null
    fi
    assert_original_aws
    ;;
  successful)
    cloud-context --load workstation >/dev/null
    [[ "$AWS_PROFILE" == work && "$AWS_REGION" == eu-west-1 &&
      ! -v AWS_DEFAULT_PROFILE ]]
    FZF_PICK=personal cloud-context --select aws >/dev/null
    [[ "$AWS_PROFILE" == personal && "$AWS_REGION" == us-east-2 ]]
    # Identical generated content must still apply to the current caller.
    export AWS_PROFILE=manual AWS_REGION=manual
    FZF_PICK=personal cloud-context --select aws >/dev/null
    [[ "$AWS_PROFILE" == personal && "$AWS_REGION" == us-east-2 ]]
    cloud-context --clear aws >/dev/null
    [[ ! -v AWS_PROFILE && ! -v AWS_REGION && ! -v AWS_DEFAULT_REGION ]]
    ;;
  fixtures)
    export KUBECONFIG="$HOME/original kube" CLOUDSDK_CONFIG="$HOME/original gcloud"
    export AWS_CONFIG_FILE="$HOME/original config" AWS_DEFAULT_PROFILE=''
    unset AWS_SHARED_CREDENTIALS_FILE AZURE_CONFIG_DIR CLOUD_CONTEXT_TEST_AWS_ACCOUNT
    cloud-context --test all --yes >/dev/null
    [[ "$AWS_PROFILE" == cloud-context-test &&
      "$CLOUD_CONTEXT_TEST_AWS_ACCOUNT" == 000000000042 &&
      "$KUBECONFIG" == *cloud-context-test/kube/config ]]
    cloud-context --test-clear aws >/dev/null
    [[ "$AWS_PROFILE" == work && "$AWS_REGION" == eu-west-1 &&
      -v AWS_DEFAULT_PROFILE && -z "$AWS_DEFAULT_PROFILE" &&
      "$AWS_CONFIG_FILE" == "$HOME/original config" &&
      ! -v AWS_SHARED_CREDENTIALS_FILE && ! -v CLOUD_CONTEXT_TEST_AWS_ACCOUNT &&
      "$KUBECONFIG" == *cloud-context-test/kube/config ]]
    cloud-context --test-clear >/dev/null
    [[ "$KUBECONFIG" == "$HOME/original kube" &&
      "$CLOUDSDK_CONFIG" == "$HOME/original gcloud" &&
      ! -v AZURE_CONFIG_DIR && "$AWS_PROFILE" == work &&
      ! -e "$XDG_STATE_HOME/dotfiles/cloud-context-test.env" &&
      ! -e "$XDG_STATE_HOME/dotfiles/cloud-context-test" ]]
    cloud-context --help >/dev/null
    [[ "$AWS_PROFILE" == work && "$AWS_REGION" == eu-west-1 ]]
    ;;
esac
ZSH
    printf 'Cloud wrapper regression failed: %s\n' "$scenario" >&2
    ((wrapper_failures += 1))
  fi
done
[[ "$wrapper_failures" == 0 ]]

# Both real CLI calls finish writing before either wrapper may source its output.
(
  export HOME="$TMP_ROOT/concurrent-home" TMPDIR="$TMP_ROOT/handoffs"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
  export REAL_CLOUD_CONTEXT="$SCRIPT" HANDOFF_BARRIER="$TMP_ROOT/barrier"
  mkdir -p "$TMP_ROOT/concurrent-bin" "$HANDOFF_BARRIER"
  cat >"$TMP_ROOT/concurrent-bin/cloud-context" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_CLOUD_CONTEXT" "$@"
printf '%s\n' "${CLOUD_CONTEXT_ENV_OUTPUT:-shared}" >"$HANDOFF_BARRIER/output-$FZF_PICK"
touch "$HANDOFF_BARRIER/$FZF_PICK"
until [[ -e "$HANDOFF_BARRIER/work" && -e "$HANDOFF_BARRIER/personal" ]]; do
  sleep 0.01
done
EOF
  chmod +x "$TMP_ROOT/concurrent-bin/cloud-context"
  export PATH="$TMP_ROOT/concurrent-bin:$PATH"
  pids=()
  for profile in work personal; do
    timeout 10 zsh -f -c '
      set -eu
      source "$1"
      FZF_PICK="$2" cloud-context --select aws >/dev/null
      [[ "$AWS_PROFILE" == "$2" ]]
    ' _ "$TMP_ROOT/wrapper.zsh" "$profile" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
  done
  work_output="$(<"$HANDOFF_BARRIER/output-work")"
  personal_output="$(<"$HANDOFF_BARRIER/output-personal")"
  [[ "$work_output" != "$personal_output" ]]
  [[ ! -e "$work_output" && ! -e "$personal_output" ]]
)

printf 'Cloud context test passed\n'
