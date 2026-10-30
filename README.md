# Idan's Dotfiles

[![CI](https://github.com/Idanbot/.dotfiles/actions/workflows/ci.yml/badge.svg)](https://github.com/Idanbot/.dotfiles/actions/workflows/ci.yml)

A personal development-environment bootstrap for Ubuntu 24.04, native or WSL2.
Chezmoi deploys configuration; one installer handles tools, verification, logs,
backups, and recovery.

## Quick Start

Interactive setup:

```bash
curl -fsSL https://raw.githubusercontent.com/Idanbot/.dotfiles/main/scripts/install.sh | bash
```

Full unattended setup:

```bash
curl -fsSL https://raw.githubusercontent.com/Idanbot/.dotfiles/main/scripts/install.sh | \
  bash -s -- --full --yes
```

Test first without changing your machine: [two-pass full Docker install](#verification).

Requires internet access and sudo. After installation, restart the shell and
check the result:

```bash
exec zsh
dot doctor
```

## Scope and Guarantees

- One successful full run installs managed tools and deploys the shell, terminal,
  editor, cloud helpers, and agent configuration.
- SSH keys, secrets, cloud/agent logins, and Windows terminal/font setup remain
  manual. This public repository contains no credentials or encrypted secrets.
- Existing histories, completion caches, credentials, and local overlays are
  preserved. Unowned or modified software is not silently adopted or replaced.
- Managed configuration is backed up before replacement. npm/uv upgrades have
  package-scoped recovery; this is not whole-machine rollback.
- Two-pass Docker tests check managed-state convergence. Reruns can still apply
  approved or policy-allowed updates; the environment is not frozen forever.

Supported targets are Ubuntu 24.04 amd64/arm64 on native Linux and WSL2.
Docker cannot prove GUI, physical-device, or Windows interoperability behavior.

## Install Profiles

| Profile | Scope |
| --- | --- |
| `minimal` | Core packages |
| `base` | Shell and terminal utilities |
| `developer` | Languages, history, tmux/Herdr, Neovim, system and theme |
| `agent` | Developer setup plus AI tools |
| `cloud` | Developer setup plus container/cloud tools |
| `full` | All applicable sections |

From a checkout:

```bash
./scripts/install.sh --full --print-plan
./scripts/install.sh --with ai,neovim --yes
./scripts/install.sh --full --without cloud,vscode --yes
./scripts/install.sh --list-options
```

`--with` starts from `base`; dependencies are added automatically.
[Selector details](docs/handbook.md#install-profiles).

## Daily Workflow

```bash
dot status                         # Source, last run, and managed installs
dot diff                           # Preview managed config changes
dot sync                           # Pull fast-forward and run the installer
dot tools sql                      # Find tools by name, purpose, or tags
dot tools --available --pick        # fzf catalog with details and examples
dot workspace "$PWD"                # Backend-aware agent workspace
dot-agent-status --check            # Agent readiness, without starting agents
agent-mcp status                    # Optional MCP integrations; off by default
cloud-context --recent              # Recent saved cloud contexts
dot privacy                        # Managed telemetry policy audit
```

Standard `cat` and `ls` are not replaced by aliases.
[Catalog](docs/handbook.md#discover-installed-software),
[workspaces](docs/handbook.md#agent-workspace),
[cloud contexts](docs/handbook.md#cloud-contexts),
[SSH and Cloudflare](docs/handbook.md#ssh-and-cloudflare-access).
A prompt context identifies selected configuration, not authenticated access.

## Configuration Conflicts

Interactive runs offer skip, replace, reviewed merge, diff, and quit.
`--yes` explicitly approves replacement after backup. Local customizations belong
in overlays such as `~/.config/dotfiles/local.zsh`, `~/.config/git/config.local`,
and `~/.ssh/config.local`.
[Conflict choices and overlay behavior](docs/handbook.md#configuration-conflicts).

## Installation Preflight

`dot preflight` reports active versions, paths, ownership, and upgrade targets.
Newer runtimes are preserved. Selected cloud tools follow reviewed update policies;
checksums/signatures are verified and cached downloads are revalidated.

Explicit named replacement is supported only by implemented backends:

```bash
DOTFILES_REPLACE_BINARIES=gh ./scripts/install.sh --only core --yes
```

Unowned npm/uv packages, Rust, legacy Java activation, distro packages, and other
unsupported takeovers require manual migration. Verified owned upgrades remain
supported. [Policies](docs/handbook.md#installation-preflight),
[integrity and update reports](docs/handbook.md#versions-and-supply-chain).

## Recovery and Logs

```bash
dot backup
dot backup verify latest
dot restore BACKUP_ID
./scripts/install.sh --resume=latest
dot logs
```

Private run records live under `~/.local/state/dotfiles/`: text logs, JSONL events,
summaries, checkpoints, and backups. Full installs keep native npm/uv progress in
the text log; warnings and error summaries remain visible. Use
`DOTFILES_VERBOSE=1` for full manager output.

Backup creation, restore, pruning, and reconciliation coordinate with bootstrap's
state lock. Snapshots become visible only after verification and atomic
publication. Lock contention fails clearly; `DOTFILES_LOCK_TIMEOUT` allows waiting.
[Recovery details](docs/handbook.md#recovery-and-resume),
[logging](docs/handbook.md#logs-and-diagnostics).

## Tools and Versions

These are reviewed repository baselines, not observed machine versions.
Profiles determine what is installed; `distro` uses signed repositories and
`standalone` uses the vendor installation policy. See
[the complete inventory](docs/tool-inventory.md) or `dot tools` for descriptions,
commands, examples, tags, and observed paths/versions.

<!-- tool-versions:start -->
| Category | Tools and Requested Versions |
| --- | --- |
| bootstrap | `chezmoi` 2.73.1 |
| core | `fzf` 0.74.5, `fd` 10.4.2, `ripgrep` 15.1.0, `bat` 0.26.1, `eza` 0.23.5, `lazygit` 0.66.1, `btop` 1.4.7, `starship` 1.26.0, `github_cli` 2.102.0, `jq` distro, `gojq` distro, `yq` distro, `pigz` distro, `zstd` distro, `htop` distro, `zoxide` distro, `direnv` distro, `git-delta` distro, `hyperfine` distro, `duf` distro, `sops` 3.13.3, `lazydocker` 0.25.2, `tealdeer` 1.9.0, `curlie` 1.8.2, `trippy` 0.13.0, `ast_grep` 0.50.0, `gitleaks` 8.30.1 |
| languages | `go` 1.27.2, `rust` 1.97.1, `cargo` 1.97.1, `node` 26.11.1, `npm` 12.2.0, `typescript` 7.0.2, `python` 3.14.9, `java` 25.0.4.1+1, `uv` 0.13.5 |
| history | `atuin` 18.23.0 |
| editor | `neovim` 0.12.6 |
| database | `usql` 0.21.4, `iredis` 1.16.1, `pgloader` distro |
| cloud | `docker` distro, `kubectl` 1.37.1, `helm` 4.3.0, `terraform` 1.16.5, `ansible` distro, `k9s` 0.51.0, `aws_cli` 2.37.12, `gcloud` distro, `azure_cli` distro, `cloudflared` 2026.10.0, `s5cmd` 2.3.0, `kcat` distro, `stern` 1.34.0, `helmfile` 1.8.1, `kubectx` 0.11.0, `kubens` 0.11.0, `kubecolor` 0.8.0, `radar` 1.16.0 |
| terminal | `kitty` 0.49.2, `tmux` distro, `tmuxp` 1.74.0, `herdr` 0.9.3 |
| system | `git_credential_manager` 3.0.1 |
| fonts | `nerd_font` FiraMono, `nerd_font_version` 3.5.1 |
| ai_tools | `claude_cli` 2.1.296, `codex_cli` standalone, `antigravity_cli` standalone, `opencode` 1.19.0, `omp` 18.12.6, `bun` 1.4.3, `serena` 1.7.0, `context_mode` 1.0.169, `graphify` 0.9.86, `rtk` 0.51.0, `ponytail` 5.1.0, `pix_optimizer` 1.3.5 |
| media | `yt_dlp` 2026.08.19, `rmpc` 0.11.0, `cava` distro |
<!-- tool-versions:end -->

## Verification

From a checkout, with Docker and Compose v2 installed:

```bash
git clone https://github.com/Idanbot/.dotfiles.git
cd .dotfiles
./scripts/e2e-shell.sh --profile full --platform native --passes 2
./scripts/e2e-shell.sh --profile full --platform wsl --passes 2
```

The wrapper runs installation and acceptance, then opens an interactive shell.
Check `DOTFILES_E2E_STATUS`; zero means validation passed. Exit to remove the
container. Logs, convergence reports, and timings remain under `artifacts/`.
WSL here is simulated; real WSL uses the separate opt-in Windows workflow.

Every push/PR runs security/static checks, behavior/selector tests, two-pass base
installs, and recovery acceptance. Heavy profiles run weekly, manually, and for
grouped upgrade canaries. [Full verification reference](docs/handbook.md#verification).
Outcome classification explains CI failures; it does not replace installation
acceptance. CVE reports are advisory and do not certify tools as vulnerability-free.

## Documentation

- [Operations handbook](docs/handbook.md): configuration, agents, contexts, SSH,
  Kitty, updates, recovery, and test commands.
- [Architecture](docs/architecture.md), [reliability](docs/reliability.md),
  [security model](docs/security-model.md), and [decisions](docs/adr/README.md).
- [Keybindings](docs/keybindings.md), [tool inventory](docs/tool-inventory.md),
  and [offline private review](docs/local-review.md).

## License

See [LICENSE](LICENSE).
