# Phase 9: GitHub Actions CI/CD

## Goal

Build strong CI that validates security, syntax, bootstrap behavior, idempotency, and real usability.

## Target Outcome

GitHub Actions proves that the repo can bootstrap cleanly on Ubuntu and that public-repo secret policy is enforced.

## Required Workflows

- `.github/workflows/security.yml`
- `.github/workflows/ci.yml`
- Optional later: `.github/workflows/nightly.yml`

## Required Jobs

- Secret scanning with `gitleaks`.
- Shell syntax/static checks.
- PowerShell parser/static checks for `install.ps1`.
- Ubuntu 24.04 bootstrap.
- Idempotency run.
- Chezmoi apply and diff.
- Ansible run and second run.
- Shell startup smoke test.
- Neovim headless smoke test.
- Mise doctor.
- Project doctor.

## Detailed Tasks

- Add security workflow that runs on push and pull request.
- Make `gitleaks` failures blocking.
- Add CI workflow with Ubuntu 24.04 runner.
- Add container-based Ubuntu 24.04 job if useful.
- Add `--ci` bootstrap path.
- Cache mise downloads if stable.
- Cache apt only if it does not hide bootstrap bugs.
- Run bootstrap twice where practical.
- Run Ansible twice and inspect changed behavior.
- Run `chezmoi diff --exit-code`.
- Run `zsh -i -c 'echo shell-ok'`.
- Run `nvim --headless '+q'`.
- Run `mise doctor`.
- Run `bash scripts/doctor.sh --ci`.
- Upload logs on failure if useful and safe.

## Acceptance Criteria

- CI fails on suspected secrets.
- CI fails on broken shell startup.
- CI fails on broken Neovim startup.
- CI fails when bootstrap is not idempotent.
- CI does not require Bitwarden or any private secret.
- CI does not leak environment values in logs.

## Tests

- Open a test branch and confirm workflows run.
- Confirm a deliberate fake secret in a temporary test branch is blocked.
- Confirm `install.sh --ci` behavior matches local expectations.

## Risks

- Full bootstrap CI may be slow. Prefer useful signal over minimal runtime, then optimize with caching.
- CI runners differ from real WSL/native machines. CI is evidence, not the only validation.

