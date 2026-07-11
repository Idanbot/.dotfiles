#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

[[ -f "$DOTFILES_DIR/.gitleaks.toml" ]]
[[ ! -e "$DOTFILES_DIR/.gitleaksignore" ]]
! grep -Eq 'encryption:[[:space:]]*age|identity:.*key\.txt|recipient:.*age1' "$DOTFILES_DIR/.chezmoi.yaml.tmpl"
! find "$DOTFILES_DIR" -path "$DOTFILES_DIR/.git" -prune -o -type f \
  \( -name 'encrypted_*' -o -name 'id_rsa' -o -name 'id_ed25519' -o -name 'key.txt' -o -name '*.kubeconfig' \) -print | grep -q .
! grep -R -E 'AKIA[0-9A-Z]{16}|-----BEGIN (OPENSSH|RSA|EC|PGP) PRIVATE KEY-----' \
  "$DOTFILES_DIR" --exclude-dir=.git --exclude='test-secret-boundary.sh' | grep -q .

for forbidden in \
  private_dot_aws private_dot_kube private_dot_gnupg encrypted_dot_ssh \
  dot_config/private_gcloud dot_config/private_gh; do
  [[ ! -e "$DOTFILES_DIR/$forbidden" ]]
done

printf 'Secret boundary test passed\n'
