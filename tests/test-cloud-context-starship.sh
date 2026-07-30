#!/usr/bin/env bash
# Verify cloud-context changes are reflected by the real Starship modules.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
command -v starship >/dev/null 2>&1 || {
  printf 'Cloud context Starship test skipped (starship unavailable)\n'
  exit 0
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export MOCK_STATE="$TMP_ROOT/provider-state"
export KUBECONFIG="$HOME/.kube/config"
export CLOUDSDK_CONFIG="$HOME/.config/gcloud"
export STARSHIP_CONFIG="$DOTFILES_DIR/dot_config/starship.toml"
MOCK_BIN="$TMP_ROOT/bin"
SCRIPT="$DOTFILES_DIR/dot_local/bin/executable_cloud-context"

mkdir -p \
  "$MOCK_BIN" "$MOCK_STATE" "$HOME/.kube" \
  "$CLOUDSDK_CONFIG/configurations" "$HOME/.aws" "$HOME/.azure" \
  "$XDG_CONFIG_HOME/dotfiles/cloud-contexts"
printf '%s\n' lab >"$MOCK_STATE/known-kube"
printf '%s\n' work >"$MOCK_STATE/known-gcloud"
printf '%s\n' work >"$MOCK_STATE/known-aws"
printf '%s\n' 00000000-0000-0000-0000-000000000001 >"$MOCK_STATE/known-azure"
printf '{"installationId":"test","subscriptions":[]}\n' \
  >"$HOME/.azure/azureProfile.json"
printf '[profile work]\nregion = eu-west-1\ncredential_process = /bin/false\n[profile personal]\nregion = us-east-2\ncredential_process = /bin/false\n' \
  >"$HOME/.aws/config"
printf 'apiVersion: v1\ncurrent-context: ""\ncontexts: []\n' >"$KUBECONFIG"

cat >"$MOCK_BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "config current-context")
    awk '/^current-context:/ {gsub(/"/, "", $2); print $2}' "$KUBECONFIG"
    ;;
  "config get-contexts lab -o name") printf 'lab\n' ;;
  "config use-context lab")
    cat >"$KUBECONFIG" <<'YAML'
apiVersion: v1
current-context: lab
contexts:
  - name: lab
    context:
      cluster: lab
      namespace: team-a
clusters:
  - name: lab
    cluster:
      server: https://example.invalid
YAML
    ;;
  "config view --minify --output jsonpath={..namespace}")
    awk '/namespace:/ {print $2; exit}' "$KUBECONFIG"
    ;;
  "config unset current-context")
    sed -i 's/^current-context:.*/current-context: ""/' "$KUBECONFIG"
    ;;
  *) exit 1 ;;
esac
EOF

cat >"$MOCK_BIN/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "auth list --filter=status:ACTIVE --format=value(account)")
    printf 'user@example.invalid\n'
    ;;
  "config configurations describe work --format=value(name)") printf 'work\n' ;;
  "config configurations activate work --quiet")
    printf 'work\n' >"$CLOUDSDK_CONFIG/active_config"
    ;;
  "config set project project-123 --quiet")
    printf '[core]\nproject = project-123\n' \
      >"$CLOUDSDK_CONFIG/configurations/config_work"
    ;;
  "config set project project-456 --quiet")
    printf '[core]\nproject = project-456\n' \
      >"$CLOUDSDK_CONFIG/configurations/config_work"
    ;;
  "projects list --filter=lifecycleState:ACTIVE --format=value(projectId) --quiet")
    printf 'project-123\nproject-456\n'
    ;;
  "config unset project --quiet")
    : >"$CLOUDSDK_CONFIG/configurations/config_work"
    ;;
  *) exit 1 ;;
esac
EOF

cat >"$MOCK_BIN/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "configure list-profiles") printf 'work\npersonal\n' ;;
  "configure get region --profile work") printf 'eu-west-1\n' ;;
  "configure get region --profile personal") printf 'us-east-2\n' ;;
  "sts get-caller-identity --query Account --output text")
    case "${AWS_PROFILE:-}" in
      work) printf '123456789012\n' ;;
      personal) printf '210987654321\n' ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF

cat >"$MOCK_BIN/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id=00000000-0000-0000-0000-000000000001
other=00000000-0000-0000-0000-000000000002
case "$*" in
  "account list --query [?id=='$id'].id -o tsv") printf '%s\n' "$id" ;;
  "account list --query [].[id,name] -o tsv")
    printf '%s\tEngineering\n%s\tSandbox\n' "$id" "$other"
    ;;
  "account set --subscription $id")
    printf '{"installationId":"test","subscriptions":[{"id":"%s","name":"Engineering","user":{"name":"test@example.invalid"},"isDefault":true}]}\n' \
      "$id" >"$HOME/.azure/azureProfile.json"
    ;;
  "account set --subscription $other")
    printf '{"installationId":"test","subscriptions":[{"id":"%s","name":"Sandbox","user":{"name":"test@example.invalid"},"isDefault":true}]}\n' \
      "$other" >"$HOME/.azure/azureProfile.json"
    ;;
  "account clear")
    printf '{"installationId":"test","subscriptions":[]}\n' \
      >"$HOME/.azure/azureProfile.json"
    ;;
  *) exit 1 ;;
esac
EOF
cat >"$MOCK_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
grep -Fx -- "$FZF_PICK"
EOF
chmod +x "$MOCK_BIN/kubectl" "$MOCK_BIN/gcloud" "$MOCK_BIN/aws" "$MOCK_BIN/az" \
  "$MOCK_BIN/fzf"
ln -s "$SCRIPT" "$MOCK_BIN/cloud-context"
export PATH="$MOCK_BIN:$PATH"

PROFILE="$XDG_CONFIG_HOME/dotfiles/cloud-contexts/work.tsv"
cat >"$PROFILE" <<'EOF'
kubectl_context	lab
gcloud_configuration	work
gcloud_project	project-123
aws_profile	work
aws_region	eu-west-1
azure_subscription	00000000-0000-0000-0000-000000000001
EOF
chmod 600 "$PROFILE"

render_module() {
  starship module "$1" 2>/dev/null |
    sed $'s/\033\\[[0-9;]*m//g'
}

load_context() {
  "$SCRIPT" "$@" >/dev/null || return
  if [[ -r "$XDG_STATE_HOME/dotfiles/cloud-context.env" ]]; then
    # shellcheck disable=SC1090
    source "$XDG_STATE_HOME/dotfiles/cloud-context.env"
  fi
  if [[ -r "$XDG_STATE_HOME/dotfiles/cloud-context-test.env" ]]; then
    # shellcheck disable=SC1090
    source "$XDG_STATE_HOME/dotfiles/cloud-context-test.env"
  fi
}

[[ "$(starship prompt --path "$TMP_ROOT" --status 0 --cmd-duration 0)" != *".aws_account"* ]]
[[ -z "$(render_module custom.kubernetes_context)" ]]
[[ -z "$(render_module gcloud)" ]]
[[ -z "$(render_module aws)" ]]
[[ -z "$(render_module custom.aws_account)" ]]
[[ -z "$(render_module azure)" ]]

load_context --load work
[[ "$(render_module custom.kubernetes_context)" == *"󱃾 lab"* ]]
[[ "$(render_module custom.kubernetes_context)" == *team-a* ]]
[[ "$(render_module gcloud)" == *project-123* ]]
[[ "$(render_module gcloud)" == ** ]]
[[ "$(render_module aws)" == *work* ]]
[[ "$(render_module aws)" == *eu-west-1* ]]
[[ "$(render_module aws)" == *" work"* ]]
[[ "$(render_module custom.aws_account)" == *123456789012* ]]
[[ "$(render_module azure)" == *Engineering* ]]
[[ "$(render_module azure)" == *"󰠅 Engineering"* ]]

FZF_PICK=project-456 load_context --select gcloud
[[ "$(render_module gcloud)" == *project-456* ]]
FZF_PICK=personal load_context --select aws
[[ "$(render_module aws)" == *personal* ]]
[[ "$(render_module aws)" == *us-east-2* ]]
[[ "$(render_module custom.aws_account)" == *210987654321* ]]
FZF_PICK=$'00000000-0000-0000-0000-000000000002\tSandbox' \
  load_context --select azure
[[ "$(render_module azure)" == *Sandbox* ]]

long_context=organization-production-europe-west1-primary-cluster
sed -i "s/current-context: lab/current-context: $long_context/" "$KUBECONFIG"
kube_prompt="$(render_module custom.kubernetes_context)"
short_context="..${long_context: -26}"
[[ "$kube_prompt" == *"󱃾 $short_context"* ]]
[[ "$kube_prompt" != *"$long_context"* ]]
sed -i "s/current-context: $long_context/current-context: lab/" "$KUBECONFIG"

load_context --clear
[[ -z "$(render_module custom.kubernetes_context)" ]]
[[ -z "$(render_module gcloud)" ]]
[[ -z "$(render_module aws)" ]]
[[ -z "$(render_module custom.aws_account)" ]]
[[ -z "$(render_module azure)" ]]

load_context --test all --yes
[[ "$(render_module custom.kubernetes_context)" == *cloud-context-test* ]]
[[ "$(render_module custom.kubernetes_context)" == *test* ]]
[[ "$(render_module gcloud)" == *cloud-context-test* ]]
[[ "$(render_module aws)" == *cloud-context-test* ]]
[[ "$(render_module aws)" == *us-east-1* ]]
[[ "$(render_module custom.aws_account)" == *000000000042* ]]
[[ "$(render_module azure)" == *"Cloud Context Test"* ]]

load_context --test-clear
[[ -z "$(render_module custom.kubernetes_context)" ]]
[[ -z "$(render_module gcloud)" ]]
[[ -z "$(render_module aws)" ]]
[[ -z "$(render_module custom.aws_account)" ]]
[[ -z "$(render_module azure)" ]]

mv "$MOCK_BIN/kubectl" "$MOCK_BIN/kubectl.disabled"
printf '#!/usr/bin/env bash\nexit 127\n' >"$MOCK_BIN/kubectl"
chmod +x "$MOCK_BIN/kubectl"
if load_context --load work 2>/dev/null; then
  echo "Profile load succeeded with an unusable kubectl" >&2
  exit 1
fi
[[ -z "$(render_module gcloud)" ]]
[[ -z "$(render_module aws)" ]]
[[ -z "$(render_module azure)" ]]

printf 'Cloud context Starship integration test passed\n'
