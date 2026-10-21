# ADR 0009: Shared Software Policy and Explicit CI Suites

Status: Accepted, 2026-10-19.

## Context

The observable orchestrator and Chezmoi deployment split remain appropriate.
Repeated manifest readers, release mappings, test lists, and E2E job bodies
made changes harder to verify. Successful installation passes did not prove
unchanged state, and some existing selector cases were missing from CI.

Review also found mismatched tagged CVE coordinates, unscored CVSS vectors,
weaker compatibility rules in advisory candidates, checksum lookup failures
treated as upstream-managed, and installation paths that could contradict the
preservation decision shown by preflight.

## Decision

Keep one orchestrator, Chezmoi source names, public commands, conflict policies,
backups, locking, and run plans. Split `scripts/lib.sh` into cohesive internal
modules behind existing helper names rather than rewriting the installer.

Use `scripts/dotfiles/metadata.py` for validated YAML interpretation. Release
tag/asset/architecture facts live in metadata; inventory, lock, and updater
consumers share them. Apply reviewed changes through parsed scalar positions
to preserve comments and layout. Generated outputs remain deterministic.

Share stable-release and Node-engine rules through `scripts/dotfiles/releases.py`.
Pin CVSS scoring separately from installation prerequisites. Query and retrieve
OSV candidates by the same exact coordinate; missing responses never mean
clean. Unknown severity does not establish improvement. npm release tags and
Node engines, and PyPI yanking, determine eligibility.

Detect checksum resolver capability separately from network success. Failed
supported resolution stays unresolved, and apply preserves tracked outputs.
Preflight and section execution preserve external, modified, and unverifiable
executables consistently, with explicit named replacement and mutation-time
ownership rechecks.

Complete `scripts/sections.json` with order, dependencies, basic acceptance,
and shared helper inputs. Generate the standalone embedded registry without
adding a pre-checkout Python requirement. Fingerprint extracted helpers and
scoped APT-key handling so helper-only changes reconcile affected sections.

Register every test as a suite entry, wrapper, or documented manual test in
`tests/suites.json`. Reject unregistered or duplicate tests. Local Docker and
hosted CI call the same runner. Prefer behavior and parsed workflow assertions
over exact source spelling.

Keep `ci.yml` as triggers/concurrency/dependencies. Two reusable workflows own
checks and gated live acceptance; a shared action retains E2E diagnostics.
Restore or build one validator image per run. Actual installation uses the minimal
base image so preinstalled validators cannot hide missing prerequisites.

The validator image uses a compiler-only build stage and a slim runtime stage.
Reuse its compressed archive by exact reviewed input hash, OS/architecture, and
UTC ISO week, with default-branch-only cache writes and no prefix fallback.
Refresh weekly to avoid indefinitely stale distro packages. Check archive
SHA256, cache identity, and loaded image ID; rebuild on cache loss/corruption,
but fail closed if a distributed same-run artifact is invalid. Cache only public
pip downloads for audit jobs and always recreate their virtual environments.
No paid cache allowance, registry, or home/credential/state cache is required.
Live acceptance remains cold so caches cannot mask bootstrap prerequisites.

Expose one `CI Result` that rejects failed, cancelled, or unexpectedly skipped
required jobs. The heavy matrix is optional only when not requested. Include
full-native alongside full-WSL acceptance. Grouped canaries recognize reusable
job-name prefixes and require all five correlated heavy profiles to pass.

Keep read-only audits, monthly write-enabled grouped upgrades, native VM, and
opt-in real WSL distinct. Daily and weekly reports share implementation;
Monday's weekly report supplies that day's CVE scan. The outcome classifier
executes only for unsuccessful outcomes using trusted default-branch code.
Existing run history and GitHub-managed agent workflows are retained.

## Validation

Docker fixtures cover CVE coordinates/scores/compatibility, failed checksums
with no mutation, metadata-driven releases, external-tool preservation,
helper fingerprints, standalone profiles, and CI failure/skip semantics.

Two-pass tests compare hashes, modes, symlink targets, executable replacement,
normalized ownership, config diffs, local histories/overlays, and backup
inventories. Volatile logs and run timestamps are excluded. Timing budgets
remain separate from convergence correctness.

Real-Chezmoi drift fixtures cover source/local edits, private-mode changes,
retargeted symlinks, and explicit skip/replace/merge/quit choices. Repeat merges
must be no-ops without leaking shell cleanup traps. Unreadable snapshot trees
fail instead of being treated as complete inventories. Cache fixtures verify
input/platform/week invalidation, corruption, failed imports/builds, and trust
boundary mutations in workflows.

Require ordinary CI and explicit heavy canaries after structural changes,
plus native acceptance when host integrations change. Tests run only in Docker
or disposable hosted machines. Local CI Compose invocations have their own
project and cleanup scope to preserve existing user containers.

## Consequences

Tool and test additions have fewer synchronization points. Shared policies
reach install and advisory consumers together while public commands remain
compatible. Validator image transfer has a cost to measure. Real WSL still
needs the private runner; branch protection remains an owner setting.
