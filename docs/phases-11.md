# Phase 11: Update, Backup, Recovery, and Uninstall

## Goal

Implement safe day-2 operations after initial bootstrap works.

## Target Outcome

The project can update itself, re-apply changes, create backups, support recovery workflows, and uninstall safely.

## Required Files

- `scripts/backup.sh`
- `scripts/update.sh`
- `scripts/uninstall-plan.sh`
- `scripts/uninstall.sh`
- `docs/RECOVERY.md`
- `docs/TROUBLESHOOTING.md`

## Update Behavior

`make update` should:

- Fetch and fast-forward the repo.
- Refuse unsafe dirty-state updates unless explicitly allowed.
- Run `chezmoi diff`.
- Run `chezmoi apply`.
- Run Ansible if relevant.
- Run `mise install`.
- Optionally run `mise upgrade` only when explicitly requested.
- Run doctor.

## Backup Behavior

`make backup` should:

- Back up managed config state.
- Avoid collecting raw secrets by default.
- Support encrypted backup mode later.
- Include recovery instructions.

## Recovery Behavior

Recovery docs should cover:

- Lost laptop.
- New machine.
- Broken shell config.
- Broken chezmoi template.
- Missing Bitwarden session.
- SSH key rotation.
- Cloud credential re-authentication.

## Uninstall Behavior

- `make uninstall-plan` previews managed files and actions.
- `make uninstall` is conservative and backs up before removal.
- `make purge` is dangerous and requires explicit confirmation.
- No uninstall command deletes private keys by default.

## Detailed Tasks

- Implement update script.
- Implement backup script.
- Implement uninstall preview.
- Implement conservative uninstall.
- Add explicit purge confirmation.
- Document glass-break material split:
  - paper backup
  - encrypted USB
  - offsite encrypted backup
- Document key rotation.
- Document lost-machine procedure.

## Acceptance Criteria

- `make update` is idempotent and safe with clean repo state.
- Dirty repo state is detected and explained.
- `make backup` does not silently archive secrets.
- `make uninstall-plan` shows actions without changing files.
- `make purge` cannot run accidentally.

## Tests

- Run update on an already-current repo.
- Run update with local dirty state and confirm safe refusal.
- Run backup and inspect archive contents.
- Run uninstall-plan.
- Test purge confirmation path with harmless fixtures.

## Risks

- Backup scripts can accidentally collect secrets. Default to conservative scope.
- Uninstall can be destructive. Preview and confirmation are mandatory.

