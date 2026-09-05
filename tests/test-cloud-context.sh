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
  "sts get-caller-identity --query Account --output text") printf "123456789012\n" ;;
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

printf 'Cloud context test passed\n'
