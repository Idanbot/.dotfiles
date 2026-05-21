# Phase 7: Optional Secrets and Bitwarden Scaffolding

## Goal

Add explicit, optional secret workflows without making bootstrap depend on secrets.

## Target Outcome

Bitwarden integration is available through intentional commands, while basic bootstrap remains fully usable without vault access.

## Required Files

- `scripts/install-bitwarden.sh`
- `scripts/bw-get.sh`
- `scripts/apply-secrets.sh`
- `scripts/restore-ssh-key.sh`
- `docs/SECURITY.md`
- `docs/RECOVERY.md`

## Commands

- `make unlock-secrets`
- `make apply-secrets`
- `make restore-ssh-key`
- `make rotate-secrets`

## Detailed Tasks

- Install Bitwarden CLI through verified download or trusted package source.
- Create `scripts/bw-get.sh`.
- Make `bw-get.sh` fail clearly when `BW_SESSION` is missing.
- Add `make unlock-secrets` that prints the unlock command without storing session material.
- Add `make apply-secrets` as an explicit action.
- Add `make restore-ssh-key` as an explicit emergency action.
- Implement atomic secret writes:
  - write temporary file
  - validate non-empty content
  - set permissions
  - move into place
- Ensure private key restore never overwrites without backup and explicit confirmation.
- Move Cloudflare token usage toward Bitwarden-backed explicit command flow.
- Keep `~/.zshrc.local` support for local-only overrides.
- Document that `CF_TOKEN` must never be committed.

## Permissions

- `~/.ssh`: `700`
- SSH private keys: `600`
- SSH public keys: `644`
- Cloud credentials: `600`
- Kubeconfig: `600` or stricter

## Acceptance Criteria

- Basic bootstrap passes with no Bitwarden login.
- Doctor warns, not fails, when Bitwarden is unavailable in basic mode.
- Secret mode fails clearly if `BW_SESSION` is missing.
- Restored secrets are written atomically with correct permissions.
- No secret values are logged.

## Tests

- Run `make doctor` without `BW_SESSION` and confirm warning behavior.
- Run `scripts/bw-get.sh example` without `BW_SESSION` and confirm clear failure.
- Use test fixtures with fake secret values that are not real credentials.
- Run `gitleaks detect --source . --redact`.

## Risks

- Secret workflows are high-risk. Keep them explicit, narrow, and heavily documented.
- Do not optimize for fully unattended secret restoration.

