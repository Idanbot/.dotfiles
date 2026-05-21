# Phase 1: Repository Skeleton and Developer Interface

## Goal

Create the executable project structure and day-2 command interface that all later phases build on.

## Target Outcome

The repo has predictable entrypoints, empty or minimal scaffolds, and a Makefile interface that documents intended operations even before every implementation exists.

## Required Files and Directories

- `install.sh`
- `install.ps1`
- `Makefile`
- `scripts/`
- `chezmoi/`
- `ansible/`
- `tests/`
- `.github/workflows/`

## Detailed Tasks

- Create top-level `install.sh` with strict mode and argument parsing skeleton.
- Create top-level `install.ps1` with Windows preflight skeleton.
- Create `Makefile` with v1 targets:
  - `bootstrap`
  - `apply`
  - `diff`
  - `update`
  - `ansible`
  - `mise`
  - `doctor`
  - `unlock-secrets`
  - `apply-secrets`
  - `restore-ssh-key`
  - `backup`
  - `test`
  - `security`
  - `uninstall-plan`
  - `uninstall`
  - `purge`
- Ensure destructive targets are placeholders with confirmation requirements until implemented.
- Create `scripts/README.md` explaining helper script ownership.
- Create `chezmoi/README.md` explaining that managed dotfiles live there.
- Create `ansible/README.md` explaining role ownership.
- Create `tests/README.md` explaining local and CI test strategy.
- Add `.editorconfig`.
- Add `.gitignore` entries for local secret and generated files:
  - `.env`
  - `.env.*`
  - `*.local`
  - `.secrets/`
  - `secrets.env`
  - `.chezmoi.local.*`
  - test logs and temporary files

## Makefile Contract

The Makefile should be stable early. Targets may delegate to placeholder scripts, but command names should not churn unnecessarily.

Required behavior:

- `make security` runs secret scanning.
- `make doctor` runs `scripts/doctor.sh` once it exists.
- `make bootstrap` runs `bash install.sh`.
- `make test` runs local smoke tests.
- `make purge` requires explicit confirmation and must not be implemented as a silent delete.

## Acceptance Criteria

- A new contributor can inspect the repo and understand where code, docs, tests, and managed dotfiles belong.
- `make help` or the default Makefile output lists available targets.
- No target silently writes secrets or deletes files.
- Placeholder commands fail clearly if their implementation phase has not landed.

## Tests

- Run `make security`.
- Run `make help`.
- Run shell syntax checks for `install.sh` and any scripts.
- Run PowerShell parser check for `install.ps1` where available.

