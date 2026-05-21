# Phase 8: Doctor, Validation, and Local Tests

## Goal

Prove the machine is actually usable after bootstrap.

## Target Outcome

`make doctor` gives clear PASS/WARN/FAIL/SKIP output and CI/local tests validate shell, editor, mise, chezmoi, Ansible, SSH key, and environment detection.

## Required Files

- `scripts/doctor.sh`
- `tests/test-shell.sh`
- `tests/test-mise.sh`
- `tests/test-idempotency.sh`
- `tests/test-bootstrap-ubuntu.sh`
- `tests/test-security.sh`

## Doctor Flags

- `--ci`
- `--secret`
- `--verbose`
- `--json`

## Required Checks

- OS detected correctly.
- Environment detected correctly.
- `git` exists.
- `chezmoi` exists.
- Chezmoi source exists.
- `chezmoi diff` is clean after apply.
- Git identity is configured.
- `zsh` exists.
- Shell startup succeeds.
- `tmux` exists.
- `nvim` exists.
- Neovim headless startup succeeds.
- `starship` exists if expected.
- `mise` exists.
- `mise doctor` passes.
- Core tools are installed.
- SSH key exists or CI skip is justified.
- Bitwarden exists if secret mode is requested.
- `BW_SESSION` exists if secret mode is requested.
- Docker is available only if expected.
- Font cache behavior is checked or skipped appropriately.

## Severity Levels

- `PASS`: required check passed.
- `WARN`: optional or non-blocking issue.
- `FAIL`: required feature broken.
- `SKIP`: not applicable in current environment.

## Detailed Tasks

- Implement shared output helpers.
- Implement command existence checks.
- Implement environment checks using `scripts/detect-env.sh`.
- Implement shell startup check.
- Implement Neovim headless check.
- Implement mise doctor check.
- Implement chezmoi diff check.
- Implement SSH key check.
- Implement Bitwarden checks for secret mode.
- Implement Docker checks based on environment and config.
- Implement JSON output if practical.
- Add tests for expected exit codes.
- Ensure doctor has useful error messages and next steps.

## Exit Codes

- `0`: all required checks passed.
- `1`: required check failed.
- `2`: invalid usage.
- `3`: unsupported environment.

## Acceptance Criteria

- `make doctor` passes after bootstrap.
- `make doctor` is useful before bootstrap and shows actionable failures.
- `make doctor --secret` fails clearly without `BW_SESSION`.
- `make doctor --ci` skips inappropriate service checks.
- Tests cover success and failure behavior.

## Tests

- Run `bash scripts/doctor.sh`.
- Run `bash scripts/doctor.sh --ci`.
- Run `bash scripts/doctor.sh --secret` without `BW_SESSION`.
- Run all files in `tests/`.

## Risks

- Doctor can become too noisy. Keep output concise but actionable.
- Optional checks must not fail basic bootstrap.

