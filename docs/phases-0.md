# Phase 0: Public Repository Contract and Security Gate

## Goal

Define the public, safe-by-default contract for the dotfiles project before importing any live configuration.

This phase is mandatory because the repository is public and existing local files may contain tokens, API keys, client references, private hostnames, or other sensitive material.

## Target Outcome

The repository has clear documentation, a secret-scanning baseline, CI enforcement, and local safety rules. No existing personal dotfiles are imported in this phase.

## Decisions Locked for v1

- Supported v1 platforms are WSL2 Ubuntu 24.04 and native Ubuntu 24.04.
- Windows 11 host automation is part of v1 through `install.ps1`.
- Chezmoi is the canonical dotfile engine.
- Ansible owns OS baseline state.
- Oh My Zsh is the default shell framework.
- LazyVim is the default Neovim distribution.
- Docker in WSL prefers Docker Desktop integration.
- Important development tools are pinned through mise.
- CI must include bootstrap and idempotency tests.
- Bitwarden scaffolding exists in v1, but secrets are applied only by explicit commands.

## Public Repo Policy

The repo must be safe to clone, inspect, fork, and run in basic mode.

Do not commit:

- API tokens, passwords, private keys, recovery codes, cookies, sessions, or credentials.
- `CF_TOKEN` or any Cloudflare token.
- Bitwarden session material.
- SSH private keys.
- Cloud credentials.
- Kubeconfigs.
- Age/SOPS identities.
- Client names, internal domains, private hostnames, or private network aliases unless explicitly approved.
- Local-only machine paths that reveal sensitive context.

Potentially acceptable after explicit review:

- Git name.
- Git email.
- Public GitHub username.
- Public aliases that do not reveal private infrastructure.
- Generic workflow aliases.

## Required Files

- `README.md`
- `docs/DESIGN.md`
- `docs/BOOTSTRAP.md`
- `docs/SECURITY.md`
- `docs/RECOVERY.md`
- `docs/SUPPORTED_ENVIRONMENTS.md`
- `docs/TROUBLESHOOTING.md`
- `docs/ADR/0001-secrets-optional.md`
- `docs/ADR/0002-install-sh-is-conductor.md`
- `docs/ADR/0003-public-repo-secret-policy.md`
- `.gitleaks.toml`
- `.github/workflows/security.yml`
- `.github/workflows/ci.yml`

## Detailed Tasks

- Create the repository directory contract from the design document.
- Move the long-form design into `docs/DESIGN.md` or keep the current design file and reference it from `docs/DESIGN.md`.
- Write `docs/SECURITY.md` with the public-repo policy and explicit forbidden data classes.
- Write `docs/BOOTSTRAP.md` with supported modes:
  - `basic`
  - `secret`
  - `ci`
  - `wsl`
  - `native`
- Write `docs/SUPPORTED_ENVIRONMENTS.md` with v1 support limited to:
  - Windows 11 + WSL2 Ubuntu 24.04
  - Native Ubuntu 24.04
  - GitHub Actions Ubuntu runner
- Mark Arch, Omarchy, macOS, Fedora, and NixOS as out of v1 scope.
- Write `docs/RECOVERY.md` with the split recovery model.
- Write `docs/TROUBLESHOOTING.md` with initial failure categories.
- Add `.gitleaks.toml`.
- Add a local command for secret scanning.
- Add GitHub Actions security workflow that runs `gitleaks`.
- Make suspected secrets a blocking CI failure from the start.
- Add a pre-import rule: live dotfiles are not copied until secret scanning exists.
- Add a review rule: useful email addresses, aliases, hostnames, and personal identifiers are reviewed before commit.

## Acceptance Criteria

- `gitleaks` can be run locally against the repository.
- GitHub Actions runs `gitleaks` on pull requests and pushes.
- Documentation clearly says this is a public repo and secrets are not allowed.
- No live dotfiles have been imported yet.
- The repo explains what v1 supports and what is deferred.

## Tests

- Run `gitleaks detect --source . --redact`.
- Confirm CI fails if a synthetic test secret is introduced in a temporary branch or local test fixture.
- Confirm docs mention `CF_TOKEN` must not be committed.

## Risks

- False positives may block CI. Prefer allowlisting specific known-safe examples rather than weakening scanning globally.
- Current local dotfiles may contain secrets. Do not read/import them before this phase is complete.

