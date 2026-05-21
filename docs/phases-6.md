# Phase 6: Mise Toolchain

## Goal

Install reproducible user-space runtimes and developer CLIs through mise.

## Target Outcome

`mise install` provisions pinned critical tools and low-risk latest utilities from a committed config managed by chezmoi.

## Required Files

- `scripts/install-mise.sh`
- `chezmoi/dot_config/mise/config.toml`
- `tests/test-mise.sh`

## Versioning Policy

Pin critical tools:

- Python.
- Node LTS.
- Go.
- Terraform.
- kubectl.
- Helm major version.

Allow `latest` for lower-risk utilities where breakage is less costly:

- `jq`
- `yq`
- `lazygit`
- `lazydocker`
- `eza`
- `zoxide`
- `atuin`
- `uv` if acceptable after testing

## Detailed Tasks

- Install mise with checksum verification or an official trusted path.
- Add mise activation to zsh config.
- Add global mise config through chezmoi.
- Decide exact pinned versions for:
  - Python
  - Node
  - Go
  - Terraform
  - kubectl
  - Helm
- Keep cloud CLIs out of mise unless reliability is proven.
- Run `mise install`.
- Run `mise doctor`.
- Ensure mise shims are available in interactive shell.
- Ensure shell startup does not fail when mise is missing during early bootstrap.

## Acceptance Criteria

- `mise install` succeeds.
- `mise doctor` passes.
- Pinned tool versions are documented.
- `zsh -i -c 'mise --version'` works after bootstrap.
- CI validates mise install or a controlled subset if full install is too slow.

## Tests

- Run `bash tests/test-mise.sh`.
- Run `mise install`.
- Run `mise doctor`.
- Run `terraform version`.
- Run `kubectl version --client=true`.
- Run `python --version`.
- Run `node --version`.
- Run `go version`.

## Risks

- Mise plugins can change behavior over time. Pin versions for important tools.
- Full tool install can slow CI. Use caching or split heavy tests if needed.

