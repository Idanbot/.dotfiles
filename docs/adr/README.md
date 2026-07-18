# Architecture Decision Records

Accepted ADRs describe the current architecture. Extend an ADR when its
decision remains valid; add a new ADR that explicitly supersedes it when the
decision changes. Deferred ideas are not commitments and require their own ADR
before they become project direction.

| ADR | Status | Implementation evidence |
| --- | --- | --- |
| [0001: Secret-free public bootstrap](0001-secret-free-bootstrap.md) | Accepted | [Security model](../security-model.md), `tests/test-secret-boundary.sh` |
| [0002: Single observable orchestrator](0002-observable-orchestrator.md) | Accepted | `scripts/install.sh`, `tests/test-bootstrap-safety.sh` |
| [0003: Verified tool ownership](0003-verified-tool-ownership.md) | Accepted | `packages.meta.yaml`, `scripts/lib.sh`, `tests/test-ownership.sh` |
| [0004: Platform test strategy](0004-platform-test-strategy.md) | Accepted | `.github/e2e/compose.yaml`, `.github/workflows/wsl-e2e.yml` |
| [0005: Parameterized agent workspaces](0005-agent-workspaces.md) | Superseded | Historical tmuxp-only decision |
| [0006: Backend-aware agent workspaces](0006-backend-aware-agent-workspaces.md) | Accepted | `dot_local/bin/executable_dot-workspace`, `tests/test-agent-workspace.sh` |

The next decision record uses sequence `0007`.
