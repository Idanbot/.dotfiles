# Idan's Dotfiles

[![CI](https://github.com/Idanbot/.dotfiles/actions/workflows/ci.yml/badge.svg)](https://github.com/Idanbot/.dotfiles/actions/workflows/ci.yml)

A repeatable, observable development-environment bootstrap for Ubuntu 24.04,
both native and WSL2. Chezmoi owns configuration deployment; one explicit
orchestrator owns package installation, recovery, logging, and acceptance.

The repository is public and intentionally contains no credentials, private
keys, tokens, or encrypted secret payloads.

## Quick Start

Interactive profile selector:

```bash
curl -fsSL https://raw.githubusercontent.com/Idanbot/.dotfiles/main/scripts/install.sh | bash
```

Unattended profile:

```bash
curl -fsSL https://raw.githubusercontent.com/Idanbot/.dotfiles/main/scripts/install.sh | \
  bash -s -- --profile developer --yes
```

Preview without changing the machine:

```bash
./scripts/install.sh --profile agent --print-plan
./scripts/install.sh --list-options
```

Supported targets are Ubuntu 24.04 amd64/arm64 on native Linux and WSL2.
Unsupported platforms fail before configuration is applied.

## Install Profiles

| Profile | Intended use | Sections beyond the common shell baseline |
| --- | --- | --- |
| `minimal` | Repair or small server | Core packages only |
| `base` | Shell workstation | Zsh and terminal utilities |
| `developer` | Main development machine | Languages, Atuin, tmux, Neovim, system/theme |
| `agent` | LLM/agent workstation | Developer plus AI CLI harnesses |
| `cloud` | Infrastructure workstation | Developer plus container/cloud CLIs |
| `full` | Complete native or WSL setup | All applicable sections |

Selectors can extend or reduce a profile:

```bash
./scripts/install.sh --with ai,neovim --yes
./scripts/install.sh --full --without cloud,vscode --yes
./scripts/install.sh --sections core,languages --yes
```

`--with` starts from `base`. Profile selections automatically include the
`languages` dependency for `ai`, `tmux`, and `media`. `--sections` is exact
expert mode and does not add dependencies.

## Reliability Model

The installer follows one path for local, one-line, CI, native, and WSL runs:

1. Validate the platform and selection.
2. Create a run ID, private logs, and stage checkpoints.
3. Install bootstrap prerequisites and a checksum-verified chezmoi release.
4. Resolve the source checkout and calculate pending config changes.
5. Back up every changed or newly-created destination.
6. Apply configuration and checksum-pinned externals without running hidden
   chezmoi install scripts.
7. Run selected install sections explicitly with timing and event records.
8. Run acceptance checks and write a machine-readable summary.

Default conflict policy is `backup`. Other policies are explicit:

```bash
./scripts/install.sh --conflict-policy backup --profile base --yes
./scripts/install.sh --conflict-policy skip --profile base --yes
./scripts/install.sh --conflict-policy abort --profile base --yes
```

- `backup`: preserve pending destinations, then apply with rollback on failure.
- `skip`: preserve current config, apply only required directories/externals,
  and continue the selected tool sections.
- `abort`: stop when any managed config change is pending.

The bootstrap uses `chezmoi apply --force` only after policy handling, so it
does not enter chezmoi's per-file prompt. When running raw `chezmoi apply`, the
prompt choices mean:

- `diff`: display the proposed change; nothing is written yet.
- `overwrite`: replace this destination with the managed version.
- `all-overwrite`: replace this and all later conflicts in the same run.
- `skip`: preserve this destination and continue.
- `quit`: stop the apply immediately.

Recovery commands:

```bash
./scripts/install.sh --resume
./scripts/install.sh --resume=<run-id>
dot backup
dot restore <backup-id>
```

Backups record files, directories, symlinks, modes, checksums, and paths that
were previously absent. Restoring therefore also removes files created by a
failed apply.

## Logs and Diagnostics

Every bootstrap is logged unless `DOTFILES_LOG=0` is set:

```text
~/.local/state/dotfiles/
|-- logs/
|   |-- bootstrap-<run-id>.log
|   `-- bootstrap-<run-id>.jsonl
|-- runs/<run-id>/
|   |-- checkpoints/
|   `-- summary.json
|-- backups/
`-- installed.tsv
```

On-machine logs and state use mode `0600`. Persisted text logs have ANSI
sequences removed and common secret assignments redacted. JSONL events include
UTC time, run ID, section/stage, level, and message. The newest 20 log pairs are
retained by default.

Console color is enabled for a capable TTY and Windows Terminal on WSL. Control
it with `DOTFILES_COLOR=always|never|auto` or the standard `NO_COLOR` variable.

Useful commands:

```bash
dot status
dot logs
dot logs <run-id>
dot doctor
./scripts/doctor.sh --acceptance --sections core,zsh,terminal --json
```

## Daily Workflow

The managed `dot` command is the lifecycle entrypoint:

```text
dot status                 repository, chezmoi, run, and ledger status
dot diff                   preview managed changes
dot sync [install flags]   fast-forward pull and reliable install
dot doctor [flags]         health and acceptance checks
dot profile [name]         read or set the machine profile
dot logs [run-id]          list or follow bootstrap logs
dot backup                 list config backups
dot restore <id>           restore a config backup
dot reconcile              run only changed package sections
dot uninstall <tool>       remove a ledger-owned tool
dot workspace [directory]  open the agent tmux workspace
```

Machine-specific choices live in
`~/.config/dotfiles/machine.conf` with mode `0600`.

## Agent Workspace

The `agent` profile installs or validates Claude Code, Codex, Gemini, OpenCode,
and OMP. Codex uses OpenAI's standalone installer, OMP uses a checksum-pinned
standalone GitHub release, and npm packages use a stable user-local Node/npm
prefix. Antigravity remains a manual optional command. Authentication and
session state are never automated.

Launch the parameterized tmuxp workspace in any project:

```bash
dot workspace
dot workspace ~/Code/project
dot-workspace . --name project-agents --print
```

The workspace creates a main terminal plus Codex, Antigravity, Claude,
OpenCode, and OMP windows in the same working directory. It runs the pinned
tmuxp version through `uvx`; a missing optional agent leaves a usable login
shell instead of failing the workspace.

## Preserved Local State

The source intentionally does not own shell histories, completion caches,
credentials, or local overlays. Existing files remain in place across applies.

Local extension points:

```text
~/.config/dotfiles/local.zsh
~/.config/dotfiles/local.bash
~/.config/dotfiles/local.tmux.conf
~/.config/git/config.local
~/.ssh/config.local
```

History paths such as `~/.zsh_history`, `~/.bash_history`, `.zcompdump*`, and
local Zsh state directories are explicitly ignored. WSL also ignores native
Kitty configuration.

## Secrets Boundary

SOPS is installed as a tool, but this repository does not configure SOPS/age
encryption and does not generate an age identity. These remain manual after
bootstrap:

- SSH and GPG private keys.
- Git/GitHub credentials and Git Credential Manager authentication.
- Cloud credentials and profiles for AWS, Google Cloud, Azure, Kubernetes,
  Terraform backends, and Cloudflare.
- API tokens, environment files, password-store/keyring content.
- Claude, Codex, Gemini, OpenCode, OMP, and Antigravity authentication/session
  directories.
- Any future age private key or SOPS recovery material.

The recommended future model is still a secret-free public bootstrap plus a
separate, opt-in encrypted recovery source. See [Security Model](docs/security-model.md).

## Versions and Supply Chain

- `packages.yaml`: requested versions.
- `packages.meta.yaml`: source, owner, and integrity policy.
- `packages.lock`: generated audit view and manifest hashes.
- `.chezmoiexternal.yaml`: immutable archive refs and SHA256 values.
- `docs/tool-inventory.md`: generated readable inventory.

Downloads use upstream checksum manifests or repository-pinned SHA256 values.
APT signing keys are verified by fingerprint. GitHub Actions are pinned by
commit SHA. The weekly version audit updates verifiable pins in a pull request;
literal hashes remain manual-review changes.

Regenerate derived files after manifest edits:

```bash
./scripts/generate-package-lock.sh
./scripts/generate-tool-inventory.sh
./scripts/generate-keybinding-docs.sh
```

## CI and Docker E2E

The first CI stage runs these jobs in parallel:

- Gitleaks full-history scan.
- ShellCheck, shfmt, YAML, templates, and generated-file contracts.
- Hadolint.
- Actionlint and Zizmor `--pedantic`.
- Trivy filesystem/secret/misconfiguration scan.
- Pull-request dependency review.

All six must pass before the verified GitHub release/external smoke job. A
pre-matrix gate then unlocks selector and native/WSL-simulated unit matrices,
two-pass base installations, and failure/restore/resume tests. Developer,
agent, cloud, and full live profiles run on schedule or manual dispatch with a
maximum parallelism of two. A separate workflow targets a private Windows
self-hosted runner for a real WSL2 kernel.

Local test commands also execute inside Docker:

```bash
docker compose -f .github/e2e/compose.yaml --profile selectors run --rm selectors
docker compose -f .github/e2e/compose.yaml --profile base up --build --abort-on-container-exit
docker compose -f .github/e2e/compose.yaml --profile recovery run --rm recovery
docker compose -f .github/e2e/compose.yaml --profile agent run --rm agent
```

For manual validation, the wrapper runs a complete native-Ubuntu installation,
executes the acceptance suite, and then leaves the disposable container open at
a login shell:

```bash
./scripts/e2e-shell.sh
```

The default is `--profile full --platform native --passes 1`. The validation
result is available inside the shell as `DOTFILES_E2E_STATUS`; `0` means the
automated checks passed. Exit the shell to delete the container. Redacted logs,
run summaries, diagnostics, and timing data remain under
`artifacts/full-false/`. A first full run can take several minutes and consume
several gigabytes because it installs the complete native workstation profile.

Useful variants:

```bash
./scripts/e2e-shell.sh --passes 2             # verify installer idempotency
./scripts/e2e-shell.sh --profile agent        # smaller agent workstation
./scripts/e2e-shell.sh --platform wsl         # simulated WSL behavior
./scripts/e2e-shell.sh --no-build             # reuse the current E2E image
./scripts/e2e-shell.sh --help
```

The container validates Ubuntu package and configuration behavior, but it
cannot prove native GUI integration, physical-device behavior, or Windows/WSL
interop. Those remain acceptance checks for the target machine or the real-WSL
workflow.

E2E artifacts include redacted text logs, JSONL events, run summaries,
checkpoints, the install ledger, environment context, process/memory/disk data,
and shell-startup timing.

## Repository Map

```text
.chezmoiscripts/       explicit section implementations
.github/e2e/           Docker profile harness
.github/workflows/     CI, version audit, and real WSL workflows
dot_* / private_dot_*  chezmoi-managed configuration
profiles/              machine profile definitions
scripts/               orchestrator, recovery, doctor, update helpers
tests/                 contracts, units, fixtures, and E2E drivers
agents.yaml            agent command registry
packages*.yaml         version and ownership manifests
```

Design details and decisions:

- [Architecture](docs/architecture.md)
- [Reliability](docs/reliability.md)
- [Security Model](docs/security-model.md)
- [Implemented Improvements](docs/improvements-2026.md)
- [ADRs](docs/adr/README.md)

## License

Personal configuration repository. Reuse selectively and review every setting
before applying it to another account or machine.
