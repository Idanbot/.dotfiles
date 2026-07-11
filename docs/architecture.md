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
| `scripts/lib.sh` | Platform-independent logging, versions, verified downloads, APT, ledger | Workflow policy |
| `scripts/environment.sh` | Native/WSL, Ubuntu release, architecture, color capability | Tool installation |
| `scripts/doctor.sh` | Verifying the selected postcondition | Repairing failures |
| `dot` | Daily lifecycle commands | Hidden background synchronization |

There is one installation orchestrator. Chezmoi scripts are rendered and run
explicitly with `chezmoi execute-template`; `chezmoi apply` excludes scripts.
This prevents duplicate or opaque execution paths.

## Bootstrap Flow

```text
selector -> private run state -> prerequisites -> source
         -> status -> transactional backup -> config/externals apply
         -> ordered sections -> doctor -> summary
```

Each stage writes a completion checkpoint only after success. Failure records
the current stage, line, exit status, text log, JSONL event log, and resume
command. Resume uses the original source, profile, selection, and checkpoints.

## Profiles and Sections

Profiles are data files in `profiles/`; built-in copies in the public one-line
installer allow selection before the repository exists. Source profile files
are checked against those built-ins to prevent drift.

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

- `logs/`: plain text and JSONL event streams.
- `runs/<id>/`: selected profile, source, checkpoints, status, and summary.
- `backups/`: transactional destination snapshots and manifests.
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

Version comparison and GitHub asset expansion are centralized in `scripts/lib.sh`.
Install sections use distro signatures, upstream checksum manifests, pinned
hashes, or verified signing-key fingerprints. Literal hash changes require
review; safely discoverable versions can be proposed by the version-audit
workflow.

## Agent Workspaces

`agents.yaml` is the command registry. `dot-workspace` renders one pinned tmuxp
YAML template with a validated session name and canonical working directory,
then runs tmuxp through `uvx`. Each agent starts in its own window. Missing
optional commands degrade to a login shell.

## Test Architecture

Fast contracts validate parsing, templates, policies, routing, ownership,
recovery, selectors, and generated files. Network release smoke tests execute
real downloaded binaries and apply all chezmoi externals. Docker E2E executes
the same installer path as users, twice, on native and WSL-simulated modes.

Simulation verifies platform branches; it does not claim to emulate the WSL
kernel or Windows interoperability. `.github/workflows/wsl-e2e.yml` is the
separate real-host contract.
