# Idan's Dotfiles

[![CI](https://github.com/Idanbot/.dotfiles/actions/workflows/ci.yml/badge.svg)](https://github.com/Idanbot/.dotfiles/actions/workflows/ci.yml)

A repeatable, observable development-environment bootstrap for Ubuntu 24.04,
both native and WSL2. Chezmoi owns configuration deployment; one explicit
orchestrator owns package installation, recovery, logging, and acceptance.

The repository is public and intentionally contains no credentials, private
keys, tokens, or encrypted secret payloads.

## Scope and Guarantees

Current targets are Ubuntu 24.04 amd64/arm64 on native Linux and WSL2.
Unsupported platforms fail before configuration is applied.

For supported targets, the project is designed to provide:

- One observable install path for interactive, unattended, CI, native, and WSL runs.
- A backup before managed configuration overwrites an existing destination.
- Preservation of shell history, completion caches, credentials, and local overlays.
- Integrity verification and explicit ownership metadata for downloaded tools.
- Profile-specific acceptance checks and machine-readable run records.
- Idempotent convergence: a successful second run should require no corrective work.

Explicit non-goals are Arch/macOS support, unattended authentication, credential
distribution, GUI validation in Docker, and autonomous agent commits or merges.

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

After installation:

```bash
exec zsh
dot doctor
dot status
```

## Install Profiles

| Profile | Intended use | Sections beyond the common shell baseline |
| --- | --- | --- |
| `minimal` | Repair or small server | Core packages only |
| `base` | Shell workstation | Zsh and terminal utilities |
| `developer` | Main development machine | Languages, Atuin, tmux/Herdr, Neovim, system/theme |
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

The common terminal baseline includes `jq`, `gojq`, `pigz`, `zstd`, `curlie`,
`ast-grep`, `gitleaks`, `bat`, and `eza`. Enhanced tools keep their own command names: standard
commands such as `cat` and `ls` are not replaced by aliases. The cloud profile
adds `s5cmd`, `kcat`, `stern`, `helmfile`, `kubectx`, `kubens`, and `kubecolor`;
database utilities
include `usql`, `iredis`, and `pgloader`.

When `kubecolor` is installed, interactive Bash and Zsh sessions alias `kubectl`
to it using the upstream-supported integration. Native kubectl completion is
preserved, and Zsh/Bash completion is also registered for explicit
`kubecolor` commands. Scripts continue to resolve the real kubectl binary;
set `DOTFILES_DISABLE_KUBECOLOR=1` before starting a shell to temporarily use
plain kubectl interactively.

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

With the default `backup` policy in a terminal, the installer creates the
transactional backup first, shows a redacted bounded diff for each existing
modified destination, and asks for a decision:

- `skip` / do nothing: preserve this destination and continue.
- `replace`: apply the managed version for this destination.
- `merge` / append: for regular shell, SSH, Git, and similar text config,
  apply the managed content first and retain the current local content after a
  marked block. Repeating the merge does not duplicate the local block, and
  local content is recoverable through the backup.
  The destination remains locally modified by design, so later runs can show
  managed updates and let you merge again or skip the file.
- `all replace`: replace this and later conflicts.
- `keep all`: preserve this and later conflicts.
- `diff`: show the bounded redacted diff again.
- `quit`: cancel configuration apply; the backup remains available for restore.

Press `--yes` for deterministic noninteractive replacement after backup. In a
piped bootstrap, interactive choices are read from the controlling terminal
even though output is being logged through `tee`. If no controlling terminal is
available, the installer cancels configuration apply safely and tells you to
use `--yes` or an explicit conflict policy. Set `DOTFILES_DIFF_LINES` to change
the preview limit; the default is 160 lines. JSON and other unsupported formats
intentionally do not offer append merge.

The bootstrap uses target-specific `chezmoi apply` calls after per-file choices,
so a skipped child cannot be reapplied accidentally through a parent directory.
When running raw `chezmoi apply`, the separate chezmoi prompt choices mean:

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
dot backup verify <id>
dot restore <backup-id>
```

Backups record files, directories, symlinks, modes, checksums, and paths that
were previously absent. Restoring therefore also removes files created by a
failed apply. Every restore first validates the complete manifest and all
backed-up checksums before changing a destination; inspect a snapshot without
restoring it with `scripts/backup.sh verify <backup-id>`.

Stateful bootstrap runs are serialized with `~/.local/state/dotfiles/bootstrap.lock`
so two terminals cannot race on checkpoints, backups, or the latest-run pointer.
The default is fail-fast; use `--lock-timeout <seconds>` when a scheduled or
supervised invocation should wait for an active run.

## Logs and Diagnostics

Every bootstrap is logged unless `DOTFILES_LOG=0` is set:

```text
~/.local/state/dotfiles/
|-- bootstrap.lock
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
retained by default. JSONL fields escape quotes, backslashes, and control
characters so error messages cannot corrupt the event stream.

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

`dot doctor` validates commands, managed configuration, runtime shims, source
integrity, private state permissions, and the install ownership ledger. Use
`--quick` to skip interactive shell and tmux runtime probes, `--json` for a
JSON-only report, and `--strict` to treat warnings as failures. Failed checks
include a focused repair command where one is available.

## Daily Workflow

The managed `dot` command is the lifecycle entrypoint:

```text
dot status                 repository, chezmoi, run, and ledger status
dot diff                   preview managed changes
dot sync [install flags]   fast-forward pull and reliable install
dot doctor [flags]         health and acceptance checks
dot privacy                audit telemetry and nonessential traffic controls
dot profile [name]         read or set the machine profile
dot logs [run-id]          list or follow bootstrap logs
dot backup                 list config backups
dot restore <id>           restore a config backup
dot cache status           inspect the verified download cache
dot cache prune [days]     remove verified downloads unused for DAYS
dot reconcile              run only changed package sections
dot uninstall <tool>       remove a ledger-owned tool
dot workspace [directory]  open a backend-aware agent workspace
dot-agent-status [flags]   show registered agent CLI readiness
cloud-context [command]    save, load, inspect, or clear cloud CLI contexts
agent-mcp [command]        enable, disable, or inspect optional MCP servers
ssh-key-load [flags]       cache an SSH key passphrase in agent memory
cloudflare-ssh [command]   authenticate and connect through Cloudflare Access
```

Machine-specific choices live in
`~/.config/dotfiles/machine.conf` with mode `0600`.

## Agent Workspace

The `agent` profile installs or validates Claude Code, Codex, Antigravity CLI
(`agy`), OpenCode, and OMP. Codex and Antigravity use their vendors' verified
standalone installers, OMP uses a checksum-pinned standalone GitHub release,
and npm packages use a stable user-local Node/npm prefix. Authentication and
session state are never automated.

Launch the workspace in any project:

```bash
dot workspace
dot workspace ~/Code/project
dot workspace . --backend herdr
dot workspace . --backend tmux
dot workspace . --agents codex,claude --restart-agents
dot workspace . --backend tmux --check
dot-workspace . --name project-agents --print
```

`--backend auto` is the default. It remains in Herdr or tmux when invoked from
inside one, prefers Herdr on a bare terminal when available, and otherwise
falls back to tmuxp. It never launches one multiplexer inside the other unless
`--allow-nested` is also passed. Set `DOTFILES_WORKSPACE_BACKEND=herdr` or
`tmux` for a shell-local default.

Both backends create a main terminal plus Codex, Antigravity, Claude, OpenCode,
and OMP in the same working directory. Herdr uses one project workspace with a
tab per agent and reuses an existing workspace with the same name. The tmux
backend renders a session from the registry and runs pinned tmuxp through
`uvx`. `--agents` selects a registered subset, `--check` performs a read-only
preflight, and `--restart-agents` restarts a crashed agent without restarting a
cleanly exited or interrupted session. `dot-agent-status` shows readiness in
the terminal and tmux status bar; it never starts agents or MCP servers. A
missing optional agent leaves a usable login shell instead of failing the
workspace.

Herdr and tmux both use `Ctrl+S` as their normal prefix. Existing tmux
`send-prefix` support handles an explicitly nested Herdr. An explicitly nested
tmux session under Herdr receives `Ctrl+B` for that generated session only.
Implicit nesting remains blocked because Herdr cannot observe agents hidden
behind an inner tmux process.

Herdr configuration is managed at `~/.config/herdr/config.toml`. It provides
tmux-style pane navigation, indexed tabs/workspaces/agents, Catppuccin, compact
priority-sorted agent status, in-app notifications, and popups for lazygit,
lazydocker, k9s, btop, and `dot doctor`. Worktree shortcuts, nested Herdr, sound,
and persisted pane history are disabled. Reload a running session after config
changes with `herdr server reload-config`.

The agent install section also installs Herdr's bundled Claude, Codex,
OpenCode, and OMP integrations. These add lifecycle/session hooks but do not
authenticate an agent or copy its credentials. Inspect them with
`herdr integration status`.

Serena and context-mode are installed as optional MCP runtimes but are
disconnected from every agent by default. `agent-mcp` changes only the selected
agents and preserves unrelated configuration:

```bash
agent-mcp status all
agent-mcp enable serena
agent-mcp enable context-mode --agent codex,claude
agent-mcp disable serena --agent agy,opencode,omp
agent-mcp disable all
```

Supported agent names are `codex`, `claude`, `agy`, `opencode`, and `omp`.
Restart active agent sessions after a change. Codex and Claude are configured
through their native MCP commands; Antigravity, OpenCode, and OMP receive
atomic JSON updates. Serena resolves the project from each agent's working
directory except in Antigravity, where its agent must activate the current
project once after enabling Serena. This MCP-only toggle deliberately avoids
installing persistent hooks or plugins. Neither MCP is authenticated or granted
extra permissions.

Graphify is installed as a separate, on-demand code knowledge-graph skill for
OMP through the standard `~/.agents/skills/graphify` location. It does not run
during bootstrap, index repositories automatically, enable an MCP server, or
configure an external model backend. In an OMP session, run `/graphify .` for a
large or unfamiliar repository; generated `graphify-out/` data is ignored in
this repository.

The AI profile also installs the canonical Ponytail skill into
`~/.agents/skills/ponytail` only when that skill is missing, preserving any
existing local copy. OMP receives the pinned Pix Optimizer plugin; use
`/optimizer` inside OMP to select Caveman, RTK, and Ponytail modes. These modes
remain user-controlled rather than being enabled by bootstrap. A verified Bun
runtime is installed alongside OMP because OMP uses it for plugin management.

RTK is checksum-pinned and installed by the `agent` and `full` profiles as an
optional shell-output optimizer. Bootstrap does not install its agent hooks;
run the appropriate `rtk init` command only after reviewing the integration.
RTK telemetry is disabled in both its managed config and the shared shell
privacy policy, while local token-savings tracking and failure-only raw output
retention remain enabled.

`dot privacy` audits the enforced RTK and Claude controls, Antigravity's
preserved `enableTelemetry` setting, Codex analytics/OTEL settings, and general
`DO_NOT_TRACK`/OpenTelemetry/HashiCorp controls. Codex's existing user config is
never overwritten; the audit reports the documented settings when an explicit
opt-out is still needed. OpenCode sharing and OMP issue submission remain
explicit user actions rather than passive uploads.

A concise shared policy lives at `~/.config/agents/AGENTS.md`. Symlinks expose
it as Codex `~/.codex/AGENTS.md`, Claude `~/.claude/CLAUDE.md`, Antigravity
`~/.gemini/GEMINI.md`, OpenCode `~/.config/opencode/AGENTS.md`, and OMP
`~/.omp/agent/AGENTS.md`. Repository and directory-level instructions override
these global defaults. The policy prefers `rg`, `fdfind`/`fd`, `gojq`, `yq`,
`pigz`, `zstd`, and explicit enhanced commands without replacing core tools.

This is a supervised launcher, not a branch-isolation system. It does not
create worktrees, coordinate concurrent edits, commit, merge, or push. Use one
editing agent at a time in a working directory; use the other windows for
review, diagnosis, research, and test observation. Separate source copies are
required when concurrent writers are intentional.

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

## SSH and Cloudflare Access

The bootstrap does not save SSH login passwords or private-key passphrases.
`ssh-agent.service` keeps unlocked keys in memory, and the shell respects a
working forwarded agent before using the managed runtime socket. Load the
default Ed25519 key for eight hours, or choose a different lifetime:

```bash
ssh-key-load
ssh-key-load --lifetime 2h
ssh-key-load --list
ssh-key-load --clear
```

The managed SSH config intentionally declares no `IdentityFile`. GitHub,
GitLab, and Cloudflare host mappings are safe to deploy without keys; OpenSSH
uses standard local identities when they are restored later, while custom
identity paths belong in the untracked `~/.ssh/config.local` overlay.

For a new host, restore an existing private key manually or run the supervised
setup flow. It can create a passphrase-protected Ed25519 key, keeps the
passphrase only in `ssh-agent`, authenticates through Access, installs only the
public key, and verifies the result. The remote account may request its password
once while installing the public key:

```bash
cloudflare-ssh setup rpi4
ssh rpi4
```

Use `cloudflare-ssh setup t420 --key ~/.ssh/id_ed25519` to select a key
explicitly. `--yes` approves creation when a key is missing, but `ssh-keygen`
still prompts for its passphrase.

The managed `rpi4` and `t420` targets use `cloudflared access ssh` as their
OpenSSH transport. Plain `ssh rpi4` lets Cloudflare open authentication when
its local session is missing or expired. `cloudflare-ssh connect rpi4` is a
convenience alias for that same single SSH attempt; it does not reinterpret
generic SSH errors as expired Access authentication. Access state under
`~/.cloudflared/`, private keys, and `~/.ssh/config.local` remain local and
untracked. OpenSSH connection multiplexing reuses authenticated connections
for ten minutes without persisting a password.

HTTPS Git authentication for `github.com` and `gist.github.com` uses GitHub CLI
as the primary and exclusive host-specific helper. Run `gh auth login` after a
fresh bootstrap; switching the active account with `gh auth switch` also
switches credentials used by Git. Other HTTPS Git hosts use
`git-credential-dotfiles`, which dispatches to Windows Git Credential Manager
on WSL when available and otherwise to the managed Linux GCM. If no GCM exists,
the dispatcher exits silently so Git can use its normal interactive prompt.
Bootstrap configures these helpers but never logs in or copies authentication
state.

## Secrets Boundary

SOPS is installed as a tool, but this repository does not configure SOPS/age
encryption and does not generate an age identity. These remain manual after
bootstrap:

- SSH and GPG private keys.
- Git/GitHub credentials and Git Credential Manager authentication.
- Cloud credentials and profiles for AWS, Google Cloud, Azure, Kubernetes,
  Terraform backends, and Cloudflare.
- API tokens, environment files, password-store/keyring content.
- Claude, Codex, Antigravity, OpenCode, and OMP authentication/session
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
Verified payloads are cached by checksum under
`~/.cache/dotfiles/downloads`; every cache read is revalidated before use and
concurrent installs share a per-object lock. Set `DOTFILES_DOWNLOAD_CACHE=0`
to bypass it or `DOTFILES_DOWNLOAD_CACHE_DIR` to relocate it. Use
`dot cache status` and `dot cache prune [days]` for maintenance.
APT signing keys are verified by fingerprint. GitHub Actions are pinned by
commit SHA. Every push and pull request publishes a non-mutating version and
checksum report. The weekly audit publishes the same report without changing
the repository. Once a month, one workflow applies all fully verified updates
to the stable `automation/grouped-tool-upgrades` branch and creates or refreshes
one review PR; it never merges automatically. Dependabot likewise groups GitHub
Actions updates into one monthly PR. The report
covers pinned GitHub/direct downloads including `ast-grep`, `gitleaks`, `s5cmd`, `stern`, `helmfile`,
`kubectx`, `kubens`, and `kubecolor`, plus RTK, Serena, context-mode, npm packages, Rust, Python, Java,
Node, and AWS CLI. Google Cloud CLI and Azure CLI are rolling tools from their
vendor-signed APT repositories and are upgraded whenever the `cloud` section
runs.

Always-on CI downloads and verifies the release assets and executes the new
CLIs. It also installs and runs the Ubuntu-managed `gojq`, `pigz`, `zstd`,
`kcat`, and `pgloader` packages before the installation matrices begin.

Check current versions and integrity values:

```bash
./scripts/update-packages.sh --check
```

The report is visible under **Actions > Version Audit** and in the `Version and
Checksum Report` job on every CI run. Trigger and inspect the standalone audit:

```bash
gh workflow run version-audit.yml
gh run list --workflow=version-audit.yml --limit 5
run_id="$(gh run list --workflow=version-audit.yml --limit 1 \
  --json databaseId --jq '.[0].databaseId')"
gh run view "$run_id"
gh run download "$run_id" --name weekly-version-checksum-report
```

Run the grouped update workflow early when needed:

```bash
gh workflow run grouped-upgrades.yml
```

Accept every fully resolved update, or only selected tools:

```bash
./scripts/update-packages.sh --apply-all
./scripts/update-packages.sh --apply core.eza@0.23.5 terminal.herdr@0.7.5
```

Kitty is installed from its official checksum-pinned Linux archive instead of
the older Ubuntu package. Check or accept the latest release with:

```bash
update-kitty --check
update-kitty --apply
```

`--apply` updates the repository version and architecture checksums, installs
that approved build, and leaves the generated manifest diff for review and
commit. Install an already-approved version with `./scripts/install-kitty.sh`.
Kitty checks daily and displays an update notification; updates are not applied
unattended.

## Cloud Contexts

Starship displays the active Kubernetes context/namespace, AWS profile and
account ID, Google Cloud project, and Azure subscription. A provider segment is
hidden when no corresponding context is active. Kubernetes contexts longer
than 28 characters retain their rightmost characters with a `..` prefix.

`cloud-context` stores context identifiers only. It never copies credentials or
tokens, and activates saved values through each provider's native CLI:

```bash
cloud-context                       # show current contexts
cloud-context --save work           # save identifiers as profile "work"
cloud-context --load work           # kubectl/gcloud/aws/az native activation
cloud-context --select gcloud       # fzf-select a project through gcloud
cloud-context --select aws          # fzf-select a local AWS profile
cloud-context --select azure        # fzf-select an Azure subscription
cloud-context --recent              # fzf-load one of five pre-clear snapshots
cloud-context --clear               # clear all four contexts
cloud-context --clear kubectl       # also: gcloud, aws, azure
cloud-context --test aws            # fake one prompt context without credentials
cloud-context --test all            # fake every prompt context in isolated configs
cloud-context --test-clear aws       # remove one fake context
cloud-context --test-clear           # remove all fake contexts
cloud-context --list
```

AWS profile selection is shell-local, so the managed Zsh wrapper sources only
`AWS_PROFILE` and region values after load/clear. Kubernetes uses
`kubectl config`, GCloud uses named configurations and project selection, and
Azure uses `az account`. Saved profiles are mode `0600` under
`~/.config/dotfiles/cloud-contexts/`.

GCP, AWS, and Azure selectors prioritize the five most recently selected values
before the full provider-native list. Before each `--clear`, the command stores
the active identifiers as a short UTC timestamp under `.recent-profiles/` and
keeps only the newest five. These snapshots contain identifiers, never
credentials, and `--recent` loads one through the same preflighted native CLI
path as a named profile.

Test contexts live under `~/.local/state/dotfiles/cloud-context-test/` and use
temporary `KUBECONFIG`, `CLOUDSDK_CONFIG`, AWS config, and `AZURE_CONFIG_DIR`
overrides. The Zsh wrapper applies and removes those overrides in the current
shell, then prints the active fake contexts. `--test` asks before running
`--test-clear`; automation must opt in with `--yes`. Real provider configuration
and credentials are not changed.

Loading preflights the saved Kubernetes context, GCloud configuration, AWS
profile, and cached Azure subscription before changing any provider. Missing
CLIs or unknown local identifiers fail without applying the profile. A GCloud
project ID is still accepted by GCloud itself because validating whether the
remote project exists would require an authenticated network request. Starship
reads the resulting native provider state on every prompt; cleared or
unauthenticated contexts render no segment.

Kitty tabs are displayed vertically on the left. The configured controls are:

| Action | Key |
|--------|-----|
| New tab in the current directory | `Ctrl+Shift+T` |
| Close current tab | `Ctrl+Shift+Q` |
| Next / previous tab | `Ctrl+Shift+Right` / `Ctrl+Shift+Left` |
| Move tab forward / backward | `Ctrl+Shift+.` / `Ctrl+Shift+,` |
| Select from all tabs | `Ctrl+Shift+Space` |
| Jump to tab 1-9 | `Ctrl+Alt+1` through `Ctrl+Alt+9` |

The report shows old and candidate versions plus SHA256 or package-registry
integrity deltas. Apply mode updates requested versions, both architecture
pins where required, `packages.lock`, and the generated tool inventory. Review
the diff and run Docker verification before committing and pushing it. Prefer
the report's version-qualified commands so a later upstream release cannot
expand the approval implicitly.

Regenerate derived files after manifest edits:

```bash
./scripts/generate-package-lock.sh
./scripts/generate-tool-inventory.sh
./scripts/generate-keybinding-docs.sh
```

## Verification

Verification is tiered so a green result has a precise meaning:

| Tier | Trigger | Coverage |
| --- | --- | --- |
| Push/PR CI | Every change | Security and policy checks, selector matrices, native/WSL-simulated units, two-pass base install, recovery/restore/resume |
| Heavy Docker E2E | Weekly or manual | Live `developer`, `agent`, `cloud`, and `full` profile installations |
| Real WSL2 | Manual, private self-hosted Windows runner | Actual WSL kernel, Windows interop, and target-machine acceptance |

The first push/PR stage runs these jobs in parallel:

- Gitleaks full-history scan.
- ShellCheck, shfmt, YAML, templates, and generated-file contracts.
- Hadolint.
- Actionlint and Zizmor `--pedantic`.
- Trivy filesystem/secret/misconfiguration scan.
- Pull-request dependency review.
- Non-mutating latest-version and checksum report with a downloadable artifact.

All seven must pass before the verified GitHub release/external smoke job. A
pre-matrix gate then unlocks the normal matrices. A green push/PR run does not
mean the scheduled heavy profiles or real-WSL workflow ran; check those tiers
when changing platform integration or complete install behavior.

Local test commands also execute inside Docker:

```bash
docker compose -f .github/e2e/compose.yaml --profile selectors run --rm selectors
docker compose -f .github/e2e/compose.yaml --profile base up --build --abort-on-container-exit
docker compose -f .github/e2e/compose.yaml --profile recovery run --rm recovery
docker compose -f .github/e2e/compose.yaml --profile agent run --rm agent
```

For manual validation, the wrapper runs a complete native Ubuntu installation,
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

Useful checks inside the validation shell:

```bash
echo "$DOTFILES_E2E_STATUS"
dot doctor
nvim
tmux
dot workspace /dotfiles
```

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
interop. The monthly `Native Ubuntu VM Acceptance` workflow covers login-shell,
fontconfig, Kitty desktop, and systemd integration on an ephemeral Ubuntu host.
It also restores the first-pass transactional backup, verifies file, symlink,
mode, and absent-path semantics, then reapplies the desired configuration.
Windows interoperability remains the real-WSL workflow's responsibility.

E2E artifacts include redacted text logs, JSONL events, run summaries,
checkpoints, the install ledger, environment context, process/memory/disk data,
a concise failure report, JUnit XML, and report-only performance budgets for
Zsh startup, Starship rendering, and the second installation pass. CI publishes
the performance table in the job summary. A rolling 90-day artifact adds
latest/previous deltas and median/range trends by profile and platform;
regressions are visible but do not block merges until enforcement is explicitly
enabled. CI runs also execute Hyperfine benchmarks for installer help, workspace
help, isolated cloud-context status, agent readiness, and Zsh startup; real
post-install startup timing uses the same benchmark engine. CI publishes those
artifacts and a separate outcome-classification check so GitHub
runner interruptions are distinguishable from actionable failures without
altering the original workflow conclusion.

## Repository Map

```text
.chezmoiscripts/       explicit section implementations
.github/e2e/           Docker profile harness
.github/workflows/     CI, maintenance, native VM, and real WSL workflows
dot_* / private_dot_*  chezmoi-managed configuration
profiles/              machine profile definitions
scripts/               orchestrator, recovery, doctor, update helpers
tests/                 contracts, units, fixtures, and E2E drivers
agents.yaml            agent command registry
packages*.yaml         version and ownership manifests
```

## Authoritative Documentation

Accepted ADRs and the current implementation are authoritative. Superseded
phase plans, candidate-path notes, and the old universal-deployment proposal
have been removed so unimplemented ideas are not mistaken for supported
behavior. New architectural decisions should extend or supersede an ADR.

Design details and generated references:

- [Architecture](docs/architecture.md)
- [Reliability](docs/reliability.md)
- [Security Model](docs/security-model.md)
- [Implemented Improvements](docs/improvements-2026.md)
- [ADRs](docs/adr/README.md)
- [Tool Inventory](docs/tool-inventory.md)
- [Keybindings](docs/keybindings.md)

## License

Personal configuration repository. Reuse selectively and review every setting
before applying it to another account or machine.
