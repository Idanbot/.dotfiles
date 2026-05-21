# Phase 2: Environment Detection and Bootstrap Modes

## Goal

Implement reliable environment detection so later phases can make safe decisions on WSL, native Ubuntu, CI, containers, systemd, sudo, and architecture.

## Target Outcome

`scripts/detect-env.sh` emits a stable machine-readable environment contract used by `install.sh`, Ansible, doctor, and tests.

## Required Files

- `scripts/detect-env.sh`
- `tests/test-detect-env.sh`
- `docs/SUPPORTED_ENVIRONMENTS.md`

## Detection Contract

`scripts/detect-env.sh` must detect:

- `OS_FAMILY=debian|arch|unknown`
- `DISTRO=ubuntu|arch|unknown`
- `DISTRO_VERSION=24.04|unknown`
- `ENV_KIND=wsl|native|container|github-actions`
- `HAS_SYSTEMD=true|false`
- `HAS_SUDO=true|false`
- `ARCH=x86_64|arm64|unknown`
- `PKG_MANAGER=apt|pacman|unknown`
- `IS_INTERACTIVE=true|false`

## Detailed Tasks

- Implement `scripts/detect-env.sh` with strict mode.
- Support human-readable output.
- Support shell export output for sourcing.
- Support JSON output if practical, or defer JSON to doctor.
- Detect WSL through `/proc/version`, `WSL_INTEROP`, and related indicators.
- Detect GitHub Actions through `GITHUB_ACTIONS=true`.
- Detect container through `/.dockerenv`, cgroup markers, or container environment variables.
- Detect systemd through PID 1.
- Detect sudo availability and whether passwordless sudo is likely.
- Detect Ubuntu 24.04 specifically through `/etc/os-release`.
- Fail clearly on unsupported distributions.
- Add tests with fixture files where practical.
- Document detection behavior in `docs/SUPPORTED_ENVIRONMENTS.md`.

## Acceptance Criteria

- Native Ubuntu 24.04 is detected as supported.
- WSL Ubuntu 24.04 is detected as supported.
- GitHub Actions Ubuntu runner is detected as CI.
- Containers are detected and service operations can be skipped later.
- Unsupported distributions produce actionable output.

## Tests

- Run `bash tests/test-detect-env.sh`.
- Run `bash scripts/detect-env.sh`.
- Run `bash scripts/detect-env.sh --exports`.
- Validate shellcheck passes if shellcheck is available.

## Risks

- WSL and containers are messy. Detection should prefer conservative behavior when uncertain.
- Do not use detection to silently enable dangerous operations.

