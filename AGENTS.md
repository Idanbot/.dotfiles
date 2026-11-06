# Repository Guide

This repo bootstraps a personal Ubuntu 24.04 native/WSL development environment.
Preserve existing installations, local configuration, shell history and credentials.

## Engineering Rules

- Edit chezmoi sources/templates, not deployed home-directory files.
- Reuse `scripts/lib/`, `scripts/dotfiles/`, the section registry and per-run plan.
- A ledger entry is not ownership proof. Recheck mutable paths/digests before mutation.
- Never weaken checksums, signatures, APT authentication or preservation to make tests pass.
- Authentication, SSH keys and secrets remain manual. No real provider inventory in fixtures.
- Do not publish raw logs, machine configurations, account/project IDs or credentials
  without explicit review/approval. Readiness reports must discard native CLI output.
- Do not run installation or tests on the host. Use disposable Docker with synthetic homes.

## Verification

Use `./scripts/ci/docker-suite.sh static` and `./scripts/ci/docker-suite.sh behavior`.
Use the `upgrades` suite for updater changes and `release` for live verified assets.
The live full-install harness is `./scripts/e2e-shell.sh --profile full --platform native --passes 2`.
Register new tests in `tests/suites.json`; retain useful failure logs and bounded runtimes.
Generate manifest-derived outputs with `scripts/generate-package-lock.sh` and
`scripts/generate-tool-inventory.sh` inside Docker; do not hand-edit generated sections.
Never claim full native/real WSL acceptance from mocks or simulated WSL tests.

## Agent Skills

The tracker is GitHub: `Idanbot/.dotfiles`. Use `gh`; keep commits under the user's
configured identity and add no AI co-author. Use existing bug/enhancement, area,
priority and triage labels rather than inventing a parallel tracker.
Issues #35/#49 are backlog maps; #34 is the singleton upgrade/CVE advisory.
Close only completed scope; leave umbrella issues open for remaining items.

Read [architecture](docs/architecture.md), [ADRs](docs/adr/) and the
[operations handbook](docs/handbook.md) before changing their contracts.
Keep this guide short and link authoritative docs instead of copying them.
