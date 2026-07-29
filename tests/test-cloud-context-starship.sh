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
printf '%s\n' dev-cluster >"$MOCK_STATE/known-kube"
printf '%s\n' work >"$MOCK_STATE/known-gcloud"
printf '%s\n' work >"$MOCK_STATE/known-aws"
printf '%s\n' 00000000-0000-0000-0000-000000000001 >"$MOCK_STATE/known-azure"
printf '{"installationId":"test","subscriptions":[]}\n' \
  >"$HOME/.azure/azureProfile.json"
printf '[profile work]\nregion = eu-west-1\ncredential_process = /bin/false\n' \
  >"$HOME/.aws/config"
printf 'apiVersion: v1\ncurrent-context: ""\ncontexts: []\n' >"$KUBECONFIG"

cat >"$MOCK_BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "config current-context")
    awk '/^current-context:/ {gsub(/"/, "", $2); print $2}' "$KUBECONFIG"
    ;;
  "config get-contexts dev-cluster -o name") printf 'dev-cluster\n' ;;
  "config use-context dev-cluster")
    cat >"$KUBECONFIG" <<'YAML'
apiVersion: v1
current-context: dev-cluster
contexts:
  - name: dev-cluster
    context:
      cluster: dev-cluster
      namespace: agents
clusters:
  - name: dev-cluster
    cluster:
      server: https://example.invalid
YAML
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
  "config configurations describe work --format=value(name)") printf 'work\n' ;;
  "config configurations activate work --quiet")
    printf 'work\n' >"$CLOUDSDK_CONFIG/active_config"
    ;;
  "config set project project-123 --quiet")
    printf '[core]\nproject = project-123\n' \
      >"$CLOUDSDK_CONFIG/configurations/config_work"
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
  "configure list-profiles") printf 'work\n' ;;
  "configure get region --profile work") printf 'eu-west-1\n' ;;
  "sts get-caller-identity --query Account --output text")
    [[ "${AWS_PROFILE:-}" == work ]] && printf '123456789012\n'
    ;;
  *) exit 1 ;;
esac
EOF

cat >"$MOCK_BIN/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id=00000000-0000-0000-0000-000000000001
case "$*" in
  "account list --query [?id=='$id'].id -o tsv") printf '%s\n' "$id" ;;
  "account set --subscription $id")
    printf '{"installationId":"test","subscriptions":[{"id":"%s","name":"Engineering","user":{"name":"test@example.invalid"},"isDefault":true}]}\n' \
      "$id" >"$HOME/.azure/azureProfile.json"
    ;;
  "account clear")
    printf '{"installationId":"test","subscriptions":[]}\n' \
      >"$HOME/.azure/azureProfile.json"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$MOCK_BIN/kubectl" "$MOCK_BIN/gcloud" "$MOCK_BIN/aws" "$MOCK_BIN/az"
ln -s "$SCRIPT" "$MOCK_BIN/cloud-context"
export PATH="$MOCK_BIN:$PATH"

PROFILE="$XDG_CONFIG_HOME/dotfiles/cloud-contexts/work.tsv"
cat >"$PROFILE" <<'EOF'
kubectl_context	dev-cluster
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
[[ -z "$(render_module kubernetes)" ]]
[[ -z "$(render_module gcloud)" ]]
[[ -z "$(render_module aws)" ]]
[[ -z "$(render_module custom.aws_account)" ]]
[[ -z "$(render_module azure)" ]]

load_context --load work
[[ "$(render_module kubernetes)" == *dev-cluster* ]]
[[ "$(render_module kubernetes)" == *agents* ]]
[[ "$(render_module kubernetes)" == *󱃾* ]]
[[ "$(render_module gcloud)" == *project-123* ]]
[[ "$(render_module gcloud)" == ** ]]
[[ "$(render_module aws)" == *work* ]]
[[ "$(render_module aws)" == *eu-west-1* ]]
[[ "$(render_module aws)" == ** ]]
[[ "$(render_module custom.aws_account)" == *123456789012* ]]
[[ "$(render_module azure)" == *Engineering* ]]
[[ "$(render_module azure)" == *󰠅* ]]

load_context --clear
[[ -z "$(render_module kubernetes)" ]]
[[ -z "$(render_module gcloud)" ]]
[[ -z "$(render_module aws)" ]]
[[ -z "$(render_module custom.aws_account)" ]]
[[ -z "$(render_module azure)" ]]

load_context --test all
[[ "$(render_module kubernetes)" == *cloud-context-test* ]]
[[ "$(render_module kubernetes)" == *test* ]]
[[ "$(render_module gcloud)" == *cloud-context-test* ]]
[[ "$(render_module aws)" == *cloud-context-test* ]]
[[ "$(render_module aws)" == *us-east-1* ]]
[[ "$(render_module custom.aws_account)" == *000000000042* ]]
[[ "$(render_module azure)" == *"Cloud Context Test"* ]]

load_context --test-clear
[[ -z "$(render_module kubernetes)" ]]
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
