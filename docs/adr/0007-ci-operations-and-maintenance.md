# ADR 0007: CI Operations and Maintenance

Status: Accepted

## Context

One concurrency key caused an explicit heavy run to cancel a push run on the
same ref. GitHub platform incidents appeared indistinguishable from code
failures, one-run timing reports had no trend, and per-tool update branches
would create review noise. Docker also cannot validate native login-shell,
desktop, fontconfig, or systemd integration.

## Decision

CI concurrency is event-aware. Push and pull-request runs supersede stale runs
of the same event/ref; schedules are non-cancelling; each manual dispatch has a
unique key. A trusted default-branch `workflow_run` classifier publishes a
separate diagnosis check. It marks cancellation-only and strong hosted-runner
outage signatures neutral, but it never changes the original workflow result.

Downloads stage partial files and retry before replacement. Checksum-protected
downloads replace the destination only after verification. Verified payloads
are cached by SHA256 with private permissions, read-time revalidation, and
per-object locking. Deterministic tests cover transient errors, exhausted
retries, corrupt payloads, cache recovery, and concurrent callers.

Performance samples include run/profile/platform identity. CI carries one
rolling 90-day history artifact forward and publishes per-series latest,
previous, delta, median, and range values. Raw millisecond values are retained
for comparisons, normalized seconds are available in JSON, and reports use a
shared human formatter that switches to minute/second notation for long runs.
E2E samples include first and second install passes, with the full profile's
first pass recorded as the full-install metric. These trends remain report-only.

The weekly audit remains read-only. Once per month, one trusted workflow applies
all fully resolved version/checksum candidates transactionally, validates the
tree in Docker, and creates or refreshes one stable automation PR. That PR runs
the heavy E2E matrix. Dependabot groups GitHub Actions into one separate monthly
PR. Neither automation path merges changes.

A monthly GitHub-hosted Ubuntu 24.04 VM runs a developer-plus-desktop install
twice, restores the first transactional backup, and reapplies the desired
state. It validates regular-file modes, symlink and absent-path restoration,
login shell, Kitty desktop registration, fontconfig, systemd unit
syntax/runtime when available, doctor acceptance, and Zsh startup.
Real WSL remains a separate self-hosted workflow.

## Consequences

Manual diagnostics are not lost to routine pushes, platform interruptions are
visible without hiding code failures, and upgrade review volume is bounded.
Performance history depends on rolling artifacts and can reset after artifact
expiry. Native VM acceptance costs more than Docker and therefore runs monthly
or on explicit dispatch rather than on every commit.
