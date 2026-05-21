# Phase 3: Minimal Linux Bootstrap

## Goal

Implement `install.sh` as the explicit Linux conductor for WSL Ubuntu 24.04, native Ubuntu 24.04, and CI mode.

## Target Outcome

Running `bash install.sh` installs minimum prerequisites, installs verified bootstrap tools, applies non-secret dotfiles, runs Ansible, installs mise tools, generates a per-machine SSH key if missing, and runs doctor.

## Required Files

- `install.sh`
- `scripts/install-chezmoi.sh`
- `scripts/install-mise.sh`
- `scripts/verify-download.sh`
- `scripts/generate-ssh-key.sh`
- `tests/test-bootstrap-ubuntu.sh`
- `tests/test-idempotency.sh`

## Required Flags

- `--ci`
- `--no-ansible`
- `--no-mise`
- `--no-secrets`
- `--with-secrets`
- `--dry-run`
- `--verbose`

Default behavior is basic mode with no secrets.

## Detailed Tasks

- Implement strict mode in `install.sh`.
- Parse flags without external dependencies.
- Call `scripts/detect-env.sh`.
- Refuse unsupported OSes with a clear message.
- Install Ubuntu base packages:
  - `sudo`
  - `ca-certificates`
  - `curl`
  - `wget`
  - `git`
  - `gnupg`
  - `unzip`
  - `tar`
  - `gzip`
  - `xz-utils`
  - `python3`
  - `python3-pip`
  - `openssh-client`
- Install chezmoi through a verified path.
- Initialize or point chezmoi at the repo `chezmoi/` source.
- Run `chezmoi apply` only for basic, non-secret config.
- Install Ansible if missing.
- Run `ansible-playbook ansible/site.yml` unless skipped.
- Install mise through a verified path.
- Run `mise install` unless skipped.
- Generate `~/.ssh/id_ed25519` only if no default key exists.
- Never overwrite an existing SSH private key.
- Print the public key after generation.
- Run `scripts/doctor.sh`.
- Ensure `--ci` skips interactive prompts, secret work, shell switching, and service enablement assumptions.

## Acceptance Criteria

- `bash install.sh --ci` runs successfully in GitHub Actions Ubuntu.
- Running `bash install.sh --ci` twice is safe.
- `install.sh` does not require Bitwarden.
- `install.sh` does not read local secret files except optional shell-local files explicitly designed for interactive use.
- Existing SSH keys are preserved.

## Tests

- Run `bash tests/test-bootstrap-ubuntu.sh`.
- Run `bash tests/test-idempotency.sh`.
- Run `bash install.sh --ci`.
- Run `bash install.sh --ci` twice.

## Risks

- Installing tools from release URLs creates supply-chain risk. Use checksum verification or official package repositories.
- CI containers do not prove native systemd behavior.

