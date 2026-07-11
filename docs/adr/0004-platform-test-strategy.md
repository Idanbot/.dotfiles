# ADR 0004: Platform Test Strategy

Status: Accepted

## Decision

Support Ubuntu 24.04 native and WSL2. Run native and WSL-branch simulation in
Docker for every base E2E cycle, heavy profiles on schedule/manual dispatch,
and real WSL only on a labeled private Windows runner.

## Consequences

Docker provides fast deterministic branch coverage but is never represented as
a WSL kernel test. Windows interop remains gated by the real-host workflow.
