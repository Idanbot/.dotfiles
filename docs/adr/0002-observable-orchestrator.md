# ADR 0002: Single Observable Orchestrator

Status: Accepted

## Decision

`scripts/install.sh` is the only package-install orchestrator. Chezmoi renders
and applies config/externals with scripts excluded; the orchestrator executes
selected section templates explicitly.

## Consequences

Ordering, logs, checkpoints, failure injection, resume, and acceptance are
consistent across local, one-line, CI, native, and WSL runs. Direct raw chezmoi
apply is a config operation, not the supported full bootstrap path.
