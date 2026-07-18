# Reliability and Operations

## Invariants

- Supported platform is checked before managed config sections run.
- One orchestrator determines section order.
- Existing config is backed up before overwrite by default.
- Existing shell history, completion state, and local overlays are preserved.
- A stage checkpoint is written only after the stage succeeds.
- Every selected profile ends with acceptance checks.
- A second unchanged run must report no config diff and skip installed tools.
- Every direct download is integrity-verified before installation.
- Every managed install has an ownership record.

## Failure Handling

An ERR trap records the active stage, source line, status, and resume command.
If config apply fails after a backup, the installer restores that backup unless
`DOTFILES_ROLLBACK_ON_ERROR=0` is explicitly set.

Failure injection is supported for E2E:

```bash
DOTFILES_FAIL_AT=source:after ./scripts/install.sh --profile minimal --yes
./scripts/install.sh --resume
```

The recovery suite proves that completed stages are skipped and the original
run summary becomes successful after resume.

## Observability

Console output uses timestamps, stable levels, section banners, durations, and
terminal-aware color. Persisted logs are plain text. JSONL events make stages
queryable without parsing decorated console output.

On failure, E2E bundles retain:

- Console/bootstrap logs and JSONL events.
- Run summaries and checkpoints.
- Install ownership ledger.
- Platform/environment context with common secret variables redacted.
- Disk, memory, process, APT source, and test-home inventories.
- Zsh startup timing.

## Idempotency Definition

Idempotency does not mean every command is skipped. Repository/status checks,
verified external convergence, health checks, and some cache refreshes may run
again. It means an unchanged second run does not overwrite local state, create
new managed diffs, reinstall pinned binaries, or fail because the first run
already completed.

## Update and Rollback

`dot sync` refuses a dirty source checkout, pulls with `--ff-only`, and invokes
the same installer. Manifest changes route only to affected sections through
`scripts/reconcile-packages.sh`.

Configuration rollback uses `dot restore <id>`. Tool rollback uses the install
ledger through `dot uninstall <tool>`. Distro package removal is deliberately
not automatic.

## Test Tiers

1. Static: syntax, formatting, schemas, policies, generated files.
2. Unit/fixture: versions, environment, profiles, routing, ledger, workspaces,
   backup/restore, failure/resume.
3. Release smoke: real checksummed assets, Herdr server/workspace reuse, and all external archives.
4. Base E2E: clean native and simulated-WSL install, two passes.
5. Heavy E2E: developer, agent, cloud, and full profiles.
6. Real WSL: self-hosted Windows runner with Ubuntu 24.04 WSL2.

The simulated WSL tier must never be described as a real WSL kernel test.
