# Phase 5: Ansible OS Baseline for Ubuntu and WSL

## Goal

Use Ansible to enforce OS-level packages and host state for native Ubuntu 24.04 and WSL Ubuntu 24.04.

## Target Outcome

Ansible roles install and configure required OS packages idempotently, while skipping unsupported service operations in WSL, CI, and containers.

## Required Files

- `ansible/site.yml`
- `ansible/inventory.ini`
- `ansible/group_vars/all.yml`
- `ansible/group_vars/ubuntu.yml`
- `ansible/group_vars/wsl.yml`
- `ansible/roles/common/`
- `ansible/roles/shell/`
- `ansible/roles/fonts/`
- `ansible/roles/docker/`
- `ansible/roles/wsl/`
- `ansible/roles/ubuntu/`
- `ansible/roles/cli_tools/`

## v1 Role Scope

In scope:

- Ubuntu 24.04 package baseline.
- WSL-specific behavior.
- Shell packages.
- Fonts.
- CLI packages not owned by mise.
- Docker Desktop integration checks for WSL.
- Docker Engine on native Ubuntu if expected and enabled.

Out of scope:

- Arch.
- Omarchy.
- Podman default behavior.
- macOS.
- Full cloud VM hardening.

## Detailed Tasks

- Create `site.yml` with localhost execution.
- Create inventory for local execution.
- Add group vars for all, Ubuntu, and WSL.
- Implement `common` role for universal packages and directories.
- Implement `shell` role for zsh, tmux, fzf prerequisites, and Oh My Zsh dependencies.
- Implement `fonts` role with JetBrainsMono Nerd Font as configurable default.
- Implement `ubuntu` role for apt-specific repositories and packages.
- Implement `wsl` role that avoids native service assumptions.
- Implement `docker` role:
  - Native Ubuntu may install Docker Engine when enabled.
  - WSL defaults to Docker Desktop integration checks.
  - CI/container skips daemon setup.
- Implement `cli_tools` role for OS-level tools not handled by mise.
- Add tags for each role.
- Add idempotency expectations to role docs.
- Configure readable Ansible output where practical.

## Acceptance Criteria

- `ansible-playbook ansible/site.yml` passes on native Ubuntu 24.04.
- `ansible-playbook ansible/site.yml` passes on WSL Ubuntu 24.04.
- Second run has minimal changes.
- CI/container mode skips service enablement.
- WSL does not blindly install Docker Engine.

## Tests

- Run `ansible-playbook ansible/site.yml --check` where possible.
- Run `ansible-playbook ansible/site.yml`.
- Run a second Ansible run and inspect changed tasks.
- Run role-tagged commands:
  - `ansible-playbook ansible/site.yml --tags shell`
  - `ansible-playbook ansible/site.yml --tags fonts`
  - `ansible-playbook ansible/site.yml --tags docker`

## Risks

- Some package tasks may always report changed. Document or fix them.
- WSL behavior depends on systemd availability and Docker Desktop settings.

