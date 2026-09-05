# Reliability and Operations

## Invariants

- Supported platform is checked before managed config sections run.
- One orchestrator determines section order.
- Existing config is backed up before overwrite by default.
- Concurrent bootstrap runs are serialized by a private state lock; a second
  run fails clearly unless `--lock-timeout` is supplied.
- Interactive conflicts show a bounded redacted diff and support per-file
  skip, replace, shell-only append, reviewed SSH/Git/shell merge, all-replace,
  all-skip, and quit decisions. Reviewed candidates require validation and consent.
- Interactive choices use the controlling terminal when output is piped; a
  missing terminal cancels configuration apply instead of choosing silently.
- Existing shell history, completion state, and local overlays are preserved.
- A stage checkpoint is written only after the stage succeeds.
- Every selected profile ends with acceptance checks.
- A second unchanged run must report no config diff and skip installed tools.
- Every direct download is integrity-verified before installation.
- Every cached download is keyed by and revalidated against its SHA256 digest.
- Every managed install has an ownership record.
- Backup restore preflights the complete manifest and verifies every stored
  checksum and destination ancestors before prompting or mutating a destination.
  Nonempty directories created since the snapshot are preserved.

## Failure Handling

An ERR trap records the active stage, source line, status, and resume command.
If config apply fails after a backup, the installer restores that backup unless
`DOTFILES_ROLLBACK_ON_ERROR=0` is explicitly set.

Failure injection is supported for E2E:

```bash
DOTFILES_FAIL_AT=source:after ./scripts/install.sh --profile minimal --yes
./scripts/install.sh --resume
```

Resume requires an unchanged versioned run plan. Changed source or options and
legacy checkpoints without a plan fail closed: start a new bootstrap to review
the new apply plan. The lightweight lifecycle suite checks a failure after apply,
unchanged resume, changed-source refusal, retained attempt summaries, and
post-doctor failure with revalidation and backup-ID retention. The
minimal-install recovery suite checks failure after source and resumed apply.
Doctor is never skipped on resume; the apply backup ID persists across attempts.
Each attempt has a private summary in `runs/<id>/attempts/`; durations describe
that attempt, not a misleading cumulative installation time.

Download fault injection separately proves retries, atomic replacement, and
checksum rejection. Cache tests additionally prove cache hits, corrupt-entry
recovery, opt-out behavior, concurrent locking, and retention pruning. A
completed-workflow classifier distinguishes actionable
job failures from cancellation-only or known hosted-runner interruptions. Its
diagnostic check never replaces or edits the original CI conclusion.

## Observability

Console output uses timestamps, stable levels, section banners, durations, and
terminal-aware color. Persisted logs are plain text. JSONL events make stages
queryable without parsing decorated console output. Installer and section
events escape JSON control characters, so multi-line or unusual failure text
cannot split or invalidate the event stream.

On failure, E2E bundles retain:

- Console/bootstrap logs and JSONL events.
- Run summaries and checkpoints.
- Install ownership ledger.
- Platform/environment context with common secret variables redacted.
- Disk, memory, process, APT source, and test-home inventories.
- Zsh startup timing.

Performance samples are aggregated into a rolling artifact with latest,
previous, median, minimum, and maximum values per profile/platform metric.
Machine-readable artifacts retain millisecond values and normalized seconds;
human reports format short durations as seconds and long durations as
minute/second values while retaining the precise millisecond value in
parentheses. E2E samples include first and second install passes, and the full
profile explicitly exposes its first pass as the full-install duration.
Trends remain report-only until a budget is deliberately promoted to a gate.

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

`scripts/sections.json` is the shared implementation/dependency registry;
`scripts/section-state.py` owns canonical fingerprints for bootstrap and updates.
Only persisted selected sections (or explicit `--sections`) are reconciled.
Checksum and installer changes count as inputs, including database and system
packages. A failed section never advances its fingerprint.

Tool ownership records use serialized atomic ledger writes and destination
fingerprints. Binary/runtime candidates are smoke-tested before switching, and
ordinary write failures preserve the previous tool. Removal refuses locally
modified destinations, retains preserved APT entries, and routes UV Python
runtime removal through `uv python uninstall`. This is not a cross-filesystem
crash transaction: a crash between ownership-file updates fails closed on a
fingerprint mismatch and requires review.

## Agent and Cloud Safety

Cloud test mode is a prompt fixture, not a credential sandbox. It refuses known
provider credential overrides without printing their values. Test cloud command
behavior in a separate credential-free, network-isolated container.

MCP disable verifies native absence and aggregates failures across agents;
already-absent servers remain idempotent. Running agents may still need a restart.
Workspace names include a canonical-directory hash, and reuse verifies the
directory on both tmux and Herdr. Explicit name collisions fail instead of
switching agents into another checkout.

Monthly grouped upgrades explicitly dispatch a heavy canary and correlate its
run ID, commit, branch, workflow, and heavy job outcomes. PR comments and JSON/MD
artifacts expose pending, failed, superseded, and successful outcomes. Mocked
workflow tests do not replace a supervised live dispatch after deployment.

Use `scripts/backup.sh verify <id>` to validate a snapshot without changing the
home directory. Configuration rollback uses `dot restore <id>`. Tool rollback uses the install
ledger through `dot uninstall <tool>`. Distro package removal is deliberately
not automatic.

## Test Tiers

1. Static: syntax, formatting, schemas, policies, generated files.
2. Unit/fixture: versions, environment, profiles, routing, ledger, workspaces,
   backup/restore, failure/resume.
3. Release smoke: real checksummed assets, Herdr server/workspace reuse, and all external archives.
4. Workspace Docker E2E: both backend launch contracts, all registered agent
   commands, MCP toggles, directory propagation, and mocked failures.
5. Base E2E: clean native and simulated-WSL install, two passes.
6. Heavy E2E: developer, agent, cloud, and full profiles.
7. Native VM: real two-pass Ubuntu host integration plus transactional
   restore/reapply acceptance on a monthly ephemeral VM.
8. Real WSL: self-hosted Windows runner with Ubuntu 24.04 WSL2.

The simulated WSL tier must never be described as a real WSL kernel test.
