# Architecture

## Purpose

This repository backs up and deploys one personal Ubuntu development
environment. The supported production targets are Ubuntu 24.04 native and
Ubuntu 24.04 under WSL2. Reliability, repeatability, and understandable failure
handling take precedence over supporting more platforms.

## Ownership Boundaries

| Component | Owns | Does not own |
| --- | --- | --- |
| Chezmoi | Rendering and deploying configuration files and pinned externals | Package orchestration and user authentication |
| `scripts/install.sh` | Selection, order, logs, checkpoints, backup, rollback, acceptance | Secret recovery or interactive tool login |
| Section scripts | Installing one capability and recording ownership | Selecting profiles or applying config |
| `scripts/lib.sh` | Stable interface loading cohesive modules under `scripts/lib/` | Workflow policy |
| `scripts/dotfiles/` | Validated manifests and shared release/compatibility policy | Installation side effects |
| `scripts/environment.sh` | Native/WSL, Ubuntu release, architecture, color capability | Tool installation |
| `scripts/doctor.sh` | Verifying the selected postcondition | Repairing failures |
| `dot` | Daily lifecycle commands | Hidden background synchronization |

There is one installation orchestrator. Chezmoi scripts are rendered and run
explicitly with `chezmoi execute-template`; `chezmoi apply` excludes scripts.
This prevents duplicate or opaque execution paths.

## Bootstrap Flow

```text
selector -> private run state -> prerequisites -> source -> preflight/version plan
         -> status -> transactional backup -> config/externals apply
         -> ordered sections -> doctor -> summary
```

Each stage writes a completion checkpoint only after success. Failure records
the current stage, line, exit status, text log, JSONL event log, and resume
command. Resume uses the original source, profile, selection, and checkpoints.

## Profiles and Sections

Profiles are data files in `profiles/`; `scripts/sections.json` owns section
order, dependencies, shared implementation inputs, and basic command acceptance.
`scripts/section-registry.py` generates the standalone installer's embedded
registry, so selection still works before checkout. CI compares generated output
and standalone/stdin plans with checkout-backed plans.

Sections are ordered capabilities:

```text
detect core zsh terminal languages history cloud tmux neovim ai media
fonts desktop system theme vscode services
```

Profile selectors may add dependencies. Exact `--sections` mode deliberately
does not, so maintainers can isolate a section during diagnosis.

## Managed State

All bootstrap state is rooted at `~/.local/state/dotfiles` and is private by
default:

- `bootstrap.lock`: advisory lock serializing stateful bootstrap runs.
- `logs/`: plain text and JSONL event streams.
- `runs/<id>/`: selected profile, source, checkpoints, status, and summary.
- `backups/`: transactional destination snapshots and manifests, verified before restore.
- `package-sections/`: hashes used for targeted reconciliation.
- `installed.tsv`: ownership ledger for non-chezmoi installs.

The ledger records tool, version, owner, target, section, and installation time.
Removal is allowed only for recorded targets under approved prefixes; distro
package removal requires a separate opt-in flag.

## Configuration Layers

1. Public managed defaults in this source state.
2. Platform templates using `.is_wsl`/`.is_native` from the generated config.
3. Machine profile in `~/.config/dotfiles/machine.conf`.
4. Ignored local overlays for shell, tmux, Git, and SSH.
5. Unmanaged credentials and authentication state.

The last two layers are intentionally never copied into logs or the public
repository.

## Tool and Version Model

`packages.yaml` is the requested-state manifest. `packages.meta.yaml` declares
source, owner, and integrity policy. Generated `packages.lock` and the readable
tool inventory provide reviewable snapshots.

The shared metadata module parses YAML with duplicate-key and scalar validation.
Release tag/asset/architecture mappings live in `packages.meta.yaml`; inventory,
lock generation, and updater discovery consume those facts. Reviewed updates
edit parsed scalar positions, preserving comments and formatting. Failed
supported checksum resolvers remain unresolved and cannot become proposals.
Python release and Node-engine compatibility rules live in
`scripts/dotfiles/releases.py`; audit and install policy share them. Shell helper
names remain stable behind `scripts/lib.sh`.
Install sections use distro signatures, upstream checksum manifests, pinned
hashes, or verified signing-key fingerprints. Literal hash changes require
review. Push/PR CI and the weekly version audit publish a non-mutating upgrade
report. A monthly workflow materializes every fully verified candidate into one
stable canary PR; it never merges. `scripts/update-packages.sh --apply-all` or
`--apply section.tool@version` remains available for local acceptance.

Checksum-verified payloads use a content-addressed cache rooted at
`~/.cache/dotfiles/downloads`. The checksum is resolved before the payload is
requested, each object is stored under its SHA256 digest with private modes,
and every read is revalidated. Per-object `flock` locking prevents parallel
profiles from downloading or publishing the same object concurrently.

Immutable chezmoi externals retain their cache until the pinned URL changes.
External network operations retry transient failures without retrying checksum
or configuration failures or exposing partial status output. Existing unowned
release binaries remain in place with a warning; `DOTFILES_REPLACE_BINARIES`
permits named replacements only after a private backup and successful probe.
HashiCorp APT signing-key rotation updates dedicated scoped keyrings against the
reviewed upstream fingerprint while preserving repository definitions.

## Agent Workspaces

`agents.yaml` is the single command and workspace-order registry. Chezmoi
materializes it at `~/.config/dotfiles/agents.yaml` for runtime use.

`dot-workspace` resolves `auto`, `herdr`, or `tmux` before launching anything.
Auto stays in the active multiplexer, prefers Herdr from a bare terminal, and
falls back to tmuxp when Herdr is unavailable. Cross-multiplexer nesting is
rejected unless `--allow-nested` is explicit.

The Herdr backend creates or focuses one named project workspace, keeps its
root terminal tab, and creates one agent tab per registry entry through Herdr's
JSON CLI. The tmux backend renders the same registry into a tmuxp YAML session
and runs the pinned tmuxp version through `uvx`. Missing agent commands degrade
to a login shell in either backend. See ADR 0006.

## Test Architecture

Fast contracts validate parsing, templates, policies, workspace routing,
Herdr configuration, ownership, recovery, selectors, and generated files.
The Docker workspace harness invokes both backend paths with synthetic agent
CLIs, validates MCP toggles, working-directory propagation, and crash/missing
agent behavior while retaining structured artifacts. Network release smoke
tests execute real downloaded binaries, create a real Herdr workspace twice,
and apply all chezmoi externals. Docker E2E executes the same installer path as
users, twice, on native and WSL-simulated modes. A monthly ephemeral Ubuntu VM
separately validates login-shell, desktop, fontconfig, and systemd host
integration.

Simulation verifies platform branches; it does not claim to emulate the WSL
kernel or Windows interoperability. `.github/workflows/wsl-e2e.yml` remains the
separate real-WSL contract.

`tests/suites.json` accounts for every test entrypoint and documents wrappers
or manual tests. `scripts/ci/run-tests.py` executes the same suite interface in
local Docker and CI. Two reusable workflows contain parallel checks and gated
live acceptance; one final result rejects unexpected required-job skips.
Native and WSL behavior suites remain separate. The common updater fault matrix
runs once in a required upgrades suite. ShellCheck follows sources with the same
analysis flags in at most two workers.

Two-pass E2E compares destinations, normalized ownership, histories, local
overlays, configuration diffs, and replacements. Full-native and full-WSL
installs are distinct scheduled/manual targets. A validator image stage serves
tests; installation acceptance uses the minimal base stage so validators cannot
conceal missing bootstrap prerequisites.
