# Implemented Improvements

This completion record maps the 25 highest-impact recommendations to concrete
implementation and validation points.

| # | Improvement | Category | Priority | Result |
| --- | --- | --- | --- | --- |
| 1 | Profile/menu selector and unattended flags | UX | High | Six profiles, custom sections, include/exclude flags, plan output |
| 2 | One explicit installer orchestrator | Architecture | High | Chezmoi apply excludes scripts; sections run with checkpoints |
| 3 | Transactional config backup and rollback | Reliability | High | Typed manifest records existing and absent destinations |
| 4 | Resume after failure | Reliability | High | Per-stage checkpoints and persisted run selection/source |
| 5 | Structured observability | Operations | High | Private text logs, JSONL events, timing, summaries, retention |
| 6 | Post-install acceptance doctor | Quality | High | Selected-section command/config/platform/security checks |
| 7 | Central platform detection | Portability | High | Shared Ubuntu/native/WSL/architecture/color implementation |
| 8 | Preserve histories and local overlays | Data safety | High | Target-path ignores plus E2E sentinels and mode checks |
| 9 | Explicit secret-free trust boundary | Security | High | No encrypted payloads or age identities; auth remains manual |
| 10 | Verified direct downloads | Security | High | Upstream manifests, pinned SHA256, and APT key fingerprints |
| 11 | Immutable chezmoi externals | Security | High | Pinned refs/hashes plus live external apply smoke |
| 12 | Package source/owner/integrity metadata | Maintainability | High | Manifest, generated lock, and tool inventory |
| 13 | Managed-install ownership ledger | Recovery | High | Mode-0600 ledger and safe uninstall command |
| 14 | Targeted package reconciliation | Efficiency | Medium | Section hashes route only changed manifest slices |
| 15 | Central version helpers | Maintainability | Medium | Shared extraction/comparison/asset expansion with tests |
| 16 | Automated version audit | Maintenance | Medium | Weekly verified-pin update PR workflow |
| 17 | Stable Node/npm installation | Runtime | High | User-local versioned runtime and stable shims; no shell-time NVM |
| 18 | Current verified Neovim | Editor | High | Pinned upstream release, checksum, headless validation |
| 19 | Official standalone Codex install | Agents | High | Verified OpenAI installer; npm substitution removed |
| 20 | Agent CLI registry and validation | Agents | High | Claude, Codex, Gemini, OpenCode, OMP; Antigravity manual |
| 21 | Parameterized tmuxp agent workspace | Workflow | High | Current-directory windows, pinned `uvx`, graceful missing agents |
| 22 | Shell completion and startup hygiene | Shell | High | Stale fpath cleanup, conditional plugins, startup budget |
| 23 | Docker selector/profile E2E | Testing | High | Native and WSL-simulated profiles with retained diagnostics |
| 24 | Failure/recovery and real WSL contracts | Testing | High | Injected failure/resume, backup restore, self-hosted WSL workflow |
| 25 | Parallel security/static CI gates | CI/CD | High | Six parallel gates before release smoke and matrices |

The implementation intentionally keeps authentication manual and limits
production support to Ubuntu 24.04 native/WSL. Those constraints reduce
unverifiable branches and prevent a public bootstrap from becoming a secret
distribution system.
