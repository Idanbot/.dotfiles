# ADR 0004: Platform Test Strategy

Status: Accepted

## Decision

Support Ubuntu 24.04 native and WSL2. Run native and WSL-branch simulation in
Docker for every base E2E cycle, heavy profiles on schedule/manual dispatch,
and real WSL only on a labeled private Windows runner.

Amendment: Accept Ubuntu 26.04 with the same profiles and select APT sources
from the installed OS release. Add a cold, two-pass 26.04 native-mode container
to heavy acceptance. Real WSL and VM coverage still use 24.04.

Ubuntu 26.04 is the default guest for native Docker acceptance (base,
developer, backup/restore, and interrupted resume). Keep the Ubuntu 24.04
full-native compatibility job and WSL guests. Shared validator containers and
GitHub runner labels stay on 24.04.

## Consequences

Docker provides fast deterministic branch coverage but is never represented as
a WSL kernel test. Windows interop remains gated by the real-host workflow.
