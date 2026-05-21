# Universal Dotfiles Deployment System

**Status:** Final design revision v1.0  
**Owner:** Idan Botbol  
**Purpose:** A secure, idempotent, cross-platform dotfiles/bootstrap system for Windows 11, WSL2, Ubuntu, Arch Linux, CI containers, cloud VMs, and personal development machines.

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Final Score](#final-score)
3. [Design Goals](#design-goals)
4. [Non-Goals](#non-goals)
5. [Supported Environments](#supported-environments)
6. [Core Architecture](#core-architecture)
7. [Responsibility Boundaries](#responsibility-boundaries)
8. [Key Design Decisions](#key-design-decisions)
9. [Repository Layout](#repository-layout)
10. [Phase 0: Repository Contract](#phase-0-repository-contract)
11. [Phase 1: Windows Entrypoint](#phase-1-windows-entrypoint)
12. [Phase 2: Minimal Linux Bootstrap](#phase-2-minimal-linux-bootstrap)
13. [Phase 3: Chezmoi Dotfile Rendering](#phase-3-chezmoi-dotfile-rendering)
14. [Phase 4: Ansible OS Baseline](#phase-4-ansible-os-baseline)
15. [Phase 5: Mise Toolchain](#phase-5-mise-toolchain)
16. [Phase 6: Optional Secrets](#phase-6-optional-secrets)
17. [Phase 7: Validation and Doctor](#phase-7-validation-and-doctor)
18. [Phase 8: Day-2 Operations](#phase-8-day-2-operations)
19. [CI/CD and Reliability Testing](#cicd-and-reliability-testing)
20. [Security Model](#security-model)
21. [Secret Handling Model](#secret-handling-model)
22. [SSH Key Strategy](#ssh-key-strategy)
23. [Binary Download Verification](#binary-download-verification)
24. [Windows and WSL Design Notes](#windows-and-wsl-design-notes)
25. [Linux Distribution Design Notes](#linux-distribution-design-notes)
26. [Docker and Podman Strategy](#docker-and-podman-strategy)
27. [Cloud CLI Strategy](#cloud-cli-strategy)
28. [Git Identity Strategy](#git-identity-strategy)
29. [Shell Strategy](#shell-strategy)
30. [Editor Strategy](#editor-strategy)
31. [Terminal and Font Strategy](#terminal-and-font-strategy)
32. [Backup and Glass-Break Plan](#backup-and-glass-break-plan)
33. [Failure Modes and Mitigations](#failure-modes-and-mitigations)
34. [Makefile Contract](#makefile-contract)
35. [Doctor Script Contract](#doctor-script-contract)
36. [Install Script Contract](#install-script-contract)
37. [Ansible Role Contract](#ansible-role-contract)
38. [Mise Config Contract](#mise-config-contract)
39. [Chezmoi Contract](#chezmoi-contract)
40. [Detailed Architecture Decision Records](#detailed-architecture-decision-records)
41. [Implementation Checklist](#implementation-checklist)
42. [Final Review](#final-review)

---

# Executive Summary

This document defines the final design for a universal dotfiles deployment system.

The system is designed to provision a fresh machine into a productive development environment while remaining:

- **Idempotent**
- **Cross-platform aware**
- **Safe without secrets**
- **Secure by default**
- **Recoverable**
- **CI-testable**
- **Explicitly orchestrated**
- **Debuggable when something breaks**

The final architecture is:

```text
Windows / Linux fresh machine
        |
        v
install.ps1 / install.sh
        |
        v
minimal bootstrap
        |
        v
chezmoi apply basic config
        |
        v
Ansible OS baseline
        |
        v
mise toolchain install
        |
        v
optional secrets phase
        |
        v
doctor / validation
        |
        v
day-2 Makefile operations
```

The most important design decision is:

```text
A machine should be useful without Bitwarden or private secrets.
Secrets are an optional second phase, not a hard dependency of bootstrap.
```

This single decision dramatically improves reliability. It means a fresh machine, CI runner, cloud VM, WSL distro, or broken recovery environment can still become usable even if Bitwarden login fails.

---

# Final Score

## Original Plan Score

The original concept had a strong architecture but dangerous implementation assumptions.

| Category | Original Score |
|---|---:|
| Architecture | 8.0 |
| Security | 5.5 |
| Idempotency | 6.5 |
| Cross-platform realism | 6.5 |
| Debuggability | 6.0 |
| Maintainability | 7.0 |
| CI reliability | 6.0 |
| Secret handling | 5.0 |
| Day-2 operations | 7.5 |
| Recovery plan | 6.0 |

**Original weighted execution score:** `6.5/10`

## Revised Plan Score

| Category | Revised Score |
|---|---:|
| Architecture | 9.5 |
| Security | 8.8 |
| Idempotency | 9.0 |
| Cross-platform realism | 8.7 |
| Debuggability | 9.4 |
| Maintainability | 9.2 |
| CI reliability | 8.8 |
| Secret handling | 8.8 |
| Day-2 operations | 9.4 |
| Recovery plan | 8.7 |

**Final weighted score:** `9.1/10`

## Why It Is Not 10/10

It is not 10/10 because true universal bootstrapping is inherently messy. Windows, WSL, Ubuntu, Arch, containers, systemd, non-systemd environments, ARM machines, cloud VMs, and personal laptops all behave differently.

The design handles this by explicitly detecting the environment and refusing to pretend that all features work everywhere.

---

# Design Goals

## Goal 1: One repo should bootstrap most personal machines

The dotfiles repo should be the source of truth for configuring:

- Windows host essentials
- WSL Ubuntu
- Native Ubuntu
- Arch Linux
- Personal laptops
- Cloud VMs
- CI test containers
- Development shells
- Editor config
- Git identity
- Developer runtimes
- CLI tools
- Optional secrets

## Goal 2: Idempotency

Running the system multiple times should be safe.

Expected behavior:

```bash
bash install.sh
bash install.sh
make doctor
make update
make doctor
```

The second and third runs should not corrupt the system, duplicate config, overwrite important user data, or re-run dangerous operations unnecessarily.

## Goal 3: Bootstrap should work without secrets

A fresh machine should still get:

- shell
- git
- tmux
- neovim
- starship
- mise
- basic CLI tools
- dotfiles
- git config
- SSH config
- machine-local SSH key

Even without:

- Bitwarden login
- SSH private key restore
- cloud credentials
- kubeconfigs
- age identity
- SOPS secrets

## Goal 4: Explicit orchestration

The main orchestration should be obvious.

Final rule:

```text
install.sh is the conductor.
chezmoi renders config.
Ansible enforces OS state.
mise installs runtimes and CLIs.
Bitwarden provides optional secrets.
doctor validates.
Makefile provides day-2 operations.
```

This prevents the system from becoming a hidden chain of side effects.

## Goal 5: Safe recovery

The system should support a glass-break path without putting all private material in one exposed bundle.

## Goal 6: CI-testable

The repo should prove that a fresh machine can bootstrap successfully.

CI should check not only that scripts exit 0, but that the resulting environment is actually usable.

---

# Non-Goals

## Non-Goal 1: Perfect support for every OS

The design does not attempt perfect support for:

- macOS
- every Linux distribution
- old unsupported Ubuntu releases
- every terminal emulator
- every shell framework
- every CPU architecture

These can be added later, but the first-class targets are Windows 11 + WSL2, Ubuntu 24.04, and Arch Linux.

## Non-Goal 2: Fully unattended secret bootstrap

The system intentionally avoids fully automatic secret restoration.

Reason:

```text
Unattended secret bootstrap increases blast radius.
A typo, compromised repo, or bad template could silently write sensitive material.
```

Secrets require an explicit unlock and apply phase.

## Non-Goal 3: Restoring the same SSH private key everywhere by default

The system should generate a fresh per-machine key by default.

Existing private key restore is an emergency/manual operation.

## Non-Goal 4: Making chezmoi do everything

Chezmoi is excellent for dotfiles. It is not used as the invisible global orchestrator.

---

# Supported Environments

## First-Class Support

| Environment | Status | Notes |
|---|---|---|
| Windows 11 + WSL2 Ubuntu 24.04 | Supported | Primary Windows workflow |
| Ubuntu 24.04 native | Supported | Main Linux target |
| Ubuntu 24.04 cloud VM | Supported | Useful for dev boxes and agents |
| Arch Linux | Supported | For personal laptops / experimental machines |
| GitHub Actions Ubuntu runner | Supported | CI target |
| Arch container in CI | Supported for smoke test | Does not prove full systemd behavior |

## Best-Effort Support

| Environment | Status | Notes |
|---|---|---|
| Raspberry Pi / ARM Linux | Best effort | Binary support must be checked |
| Older Ubuntu versions | Best effort | Package names may differ |
| Minimal containers | Partial | Services like Docker/systemd may be skipped |
| Non-systemd Linux | Partial | Service management may be skipped |

## Explicitly Unsupported Initially

| Environment | Reason |
|---|---|
| macOS | Different package manager, terminal model, security model |
| Fedora | Can be added later with dnf role |
| NixOS | Different configuration philosophy |
| Windows without WSL | Not the main dev target |

---

# Core Architecture

The architecture is a layered bootstrap pipeline.

```text
Layer 0: Repository contract
Layer 1: Windows host preparation
Layer 2: Minimal Linux bootstrap
Layer 3: Chezmoi dotfile rendering
Layer 4: Ansible OS baseline
Layer 5: Mise toolchain
Layer 6: Optional secrets
Layer 7: Validation
Layer 8: Day-2 operations
```

## Why layered architecture?

Because each layer has a different failure profile.

| Layer | Failure Risk | Recovery Method |
|---|---|---|
| Windows setup | WSL or admin permission problems | Re-run PowerShell or manually install WSL |
| Minimal bootstrap | Missing package manager or network | Install dependencies manually |
| Chezmoi | Bad templates or repo state | `chezmoi diff`, `chezmoi apply -v` |
| Ansible | Package differences, services | Role-by-role debugging |
| Mise | Plugin/version problems | Pin or install manually |
| Secrets | Bitwarden/auth/session failure | Skip until later |
| Doctor | Validation failure | Shows exact broken component |
| Makefile | Command errors | Use raw underlying commands |

Layering means failure in one layer does not necessarily destroy the entire bootstrap.

---

# Responsibility Boundaries

## `install.ps1`

Responsible for:

- Windows host prerequisites
- enabling WSL2
- installing or verifying Ubuntu 24.04
- installing Windows Terminal
- installing fonts
- backing up Windows Terminal settings
- launching Linux bootstrap inside WSL

Not responsible for:

- Linux package configuration
- SSH secrets
- cloud credentials
- editor plugin setup

## `install.sh`

Responsible for:

- environment detection
- installing minimal dependencies
- installing verified bootstrap tools
- invoking chezmoi
- invoking Ansible
- invoking mise
- generating default SSH key
- running doctor

Not responsible for:

- hiding failures
- automatically restoring secrets
- making OS-specific assumptions without detection

## `chezmoi`

Responsible for:

- rendering dotfiles
- templating non-dangerous config
- managing shell/editor/git/tmux/starship/mise config
- managing SSH config, not private keys by default

Not responsible for:

- installing OS packages
- installing Docker
- restoring private SSH keys automatically
- running the whole bootstrap secretly

## `Ansible`

Responsible for:

- OS packages
- shell packages
- fonts
- Docker/Podman where appropriate
- distro-specific state
- WSL-specific adjustments
- native Linux service setup

Not responsible for:

- language runtime versioning
- per-project developer tools
- private secrets

## `mise`

Responsible for:

- language runtimes
- user-space developer CLIs
- predictable global tool versions

Not responsible for:

- system packages
- service management
- OS repositories

## `Bitwarden`

Responsible for:

- optional secret access
- private material retrieval after explicit unlock

Not responsible for:

- making the machine usable
- being required in CI
- hiding missing session failures

## `Makefile`

Responsible for:

- day-2 operations
- consistent command interface
- update, apply, diff, doctor, backup, uninstall commands

## `doctor.sh`

Responsible for:

- validating the real state of the machine
- showing actionable failures
- separating expected missing optional features from broken required features

---

# Key Design Decisions

## Decision 1: Secrets are optional, not required

### Choice

Bootstrap basic environment without secrets. Apply secrets later through explicit commands.

### Why

If secrets are required during bootstrap, the entire system becomes fragile:

- Bitwarden CLI may not be logged in
- `BW_SESSION` may be missing
- MFA may block automation
- network may fail
- fresh machine may lack browser/auth flow
- CI cannot access secrets
- recovery machines may not have vault access

### Alternatives considered

| Alternative | Rejected Because |
|---|---|
| Require Bitwarden during bootstrap | Too fragile |
| Store secrets in repo encrypted with SOPS and auto-decrypt | Still requires age key early |
| Use same SSH private key everywhere | High blast radius |
| Manual-only setup | Too much toil |

### Result

Basic bootstrap always works. Secrets are a second phase.

---

## Decision 2: `install.sh` is the conductor

### Choice

`install.sh` explicitly calls all major phases.

### Why

Hidden orchestration causes debugging pain.

Bad pattern:

```text
install.sh calls chezmoi
chezmoi script calls Ansible
Ansible installs mise
mise runs hooks
hooks mutate shell
```

When this fails, it is hard to know who did what.

Good pattern:

```text
install.sh:
  detect
  install basics
  install chezmoi
  chezmoi apply
  ansible-playbook
  mise install
  doctor
```

### Result

Every major operation is visible in one place.

---

## Decision 3: Per-machine SSH keys by default

### Choice

Generate a fresh `ed25519` SSH key per machine.

### Why

Using one shared private key everywhere is convenient but dangerous.

If one machine is compromised, every system trusting that key is at risk.

Per-machine keys allow:

- revoking one machine
- tracking access by hostname
- safer laptop/cloud VM lifecycle
- better auditability

### Alternative

Restore a private key from Bitwarden during bootstrap.

### Rejection reason

Too much blast radius for normal use.

### Result

Default:

```bash
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)-$(date +%Y%m%d)" -f ~/.ssh/id_ed25519
```

Emergency restore:

```bash
make restore-ssh-key
```

---

## Decision 4: Verify downloaded binaries

### Choice

Every downloaded binary should be checksum-verified at minimum.

### Why

Directly downloading from GitHub is not automatically safe.

This is not enough:

```bash
curl -L -o ~/.local/bin/tool https://github.com/vendor/tool/releases/...
chmod +x ~/.local/bin/tool
```

Better:

```text
download binary
download checksum
verify checksum
install
chmod +x
```

### Result

Create a reusable `verify-download.sh` helper.

---

## Decision 5: Use Ansible for OS baseline

### Choice

Use Ansible for OS packages and system state.

### Why

Ansible is good for:

- package installation
- distro-specific tasks
- service enablement
- idempotency
- role organization
- conditionals
- readable execution output

### Alternatives considered

| Alternative | Rejected Because |
|---|---|
| Bash-only installer | Grows into unmaintainable conditionals |
| Chezmoi scripts only | Blurs config and system state |
| Nix | Too large a shift for this workflow |
| Docker-only dev env | Does not configure host machine |

### Result

Ansible owns OS-level changes.

---

## Decision 6: Use mise for developer runtimes and CLIs

### Choice

Use mise for user-space toolchains.

### Why

Apt/pacman versions drift and are often old.

Mise gives one place for:

- Python
- Node
- Go
- Terraform
- kubectl
- Helm
- k9s
- uv
- jq/yq and other CLIs

### Caveat

Not everything belongs in mise. Some heavyweight cloud CLIs may be more reliable through official installers.

---

## Decision 7: CI tests actual usability, not just script exit code

### Choice

CI should check the resulting environment.

### Why

A bootstrap script can exit 0 while producing a broken shell.

CI should test:

- idempotency
- shell startup
- editor startup
- mise doctor
- chezmoi diff
- Ansible second run
- doctor script

### Result

CI becomes useful evidence, not a false green badge.

---

# Repository Layout

Recommended final structure:

```text
dotfiles/
  README.md
  install.sh
  install.ps1
  Makefile

  docs/
    BOOTSTRAP.md
    SECURITY.md
    RECOVERY.md
    SUPPORTED_ENVIRONMENTS.md
    TROUBLESHOOTING.md
    DESIGN.md
    ADR/
      0001-secrets-optional.md
      0002-install-sh-is-conductor.md
      0003-per-machine-ssh-keys.md
      0004-verified-binary-downloads.md
      0005-ansible-for-os-baseline.md
      0006-mise-for-toolchains.md

  scripts/
    detect-env.sh
    install-chezmoi.sh
    install-mise.sh
    install-bitwarden.sh
    verify-download.sh
    bw-get.sh
    generate-ssh-key.sh
    doctor.sh
    backup.sh
    terminal-merge.ps1

  chezmoi/
    dot_zshrc.tmpl
    dot_tmux.conf
    dot_gitconfig.tmpl
    dot_gitconfig-personal.tmpl
    dot_gitconfig-work.tmpl

    dot_config/
      nvim/
      kitty/
      starship.toml
      mise/
        config.toml

    private_dot_ssh/
      config.tmpl

  ansible/
    site.yml
    inventory.ini
    group_vars/
      all.yml
      ubuntu.yml
      arch.yml
      wsl.yml
    roles/
      common/
      shell/
      fonts/
      docker/
      podman/
      wsl/
      ubuntu/
      arch/
      cli_tools/

  tests/
    test-bootstrap-ubuntu.sh
    test-bootstrap-arch.sh
    test-idempotency.sh
    test-shell.sh
    test-mise.sh
```

## Why this layout?

### Top-level files

The top level contains the main entrypoints:

- `install.sh`
- `install.ps1`
- `Makefile`
- `README.md`

This makes the repo obvious to a fresh human or agent.

### `docs/`

Documentation is kept separate from executable code.

This allows:

- clear onboarding
- design history
- recovery instructions
- security notes
- future agent readability

### `scripts/`

Small composable helpers live here.

Examples:

- detect the environment
- verify downloads
- install one tool
- run doctor
- generate SSH key

### `chezmoi/`

This is the managed dotfile source tree.

Keeping it under `chezmoi/` avoids mixing repo scripts with home-directory templates.

### `ansible/`

Ansible owns OS state and gets its own directory.

### `tests/`

CI and local smoke tests live here.

---

# Phase 0: Repository Contract

Phase 0 defines the behavior before code runs.

## Why Phase 0 exists

Without a contract, dotfiles repos become collections of assumptions.

A clear contract answers:

- What OSes are supported?
- What works without secrets?
- What requires Bitwarden?
- What is safe in CI?
- What should be skipped in containers?
- What gets installed by apt/pacman vs mise?
- What is destructive?
- What is recoverable?

## Required documentation

Create:

```text
docs/SUPPORTED_ENVIRONMENTS.md
docs/BOOTSTRAP.md
docs/SECURITY.md
docs/RECOVERY.md
docs/TROUBLESHOOTING.md
docs/DESIGN.md
```

## Bootstrap modes

Define these modes:

```text
basic mode:
  no secrets required
  installs core shell/editor/git/tooling

secret mode:
  requires Bitwarden login/unlock
  applies private material

ci mode:
  no secrets
  no real user shell switching
  no service enablement assumptions

wsl mode:
  supports WSL-specific behavior
  avoids full native Linux assumptions if unavailable

native mode:
  normal Linux behavior
  systemd and services allowed if detected
```

## Why this matters

The same command can behave differently depending on the environment.

Example:

```text
Docker Engine installation:
  native Ubuntu: install and enable service
  WSL: maybe skip or integrate with Docker Desktop
  CI container: skip service entirely
```

The repo contract prevents accidental destructive assumptions.

---

# Phase 1: Windows Entrypoint

File:

```text
install.ps1
```

## Purpose

Prepare a fresh Windows 11 machine for development through WSL2.

## Responsibilities

`install.ps1` should:

1. Check required permissions.
2. Enable WSL2.
3. Enable Virtual Machine Platform.
4. Install or verify Ubuntu 24.04.
5. Install Windows Terminal.
6. Install Nerd Font.
7. Backup existing Windows Terminal settings.
8. Patch or merge terminal settings.
9. Verify WSL distro starts.
10. Clone the dotfiles repo inside WSL.
11. Run `install.sh` inside WSL.

## Why PowerShell only handles the host

PowerShell should not configure Linux internals. That is the job of `install.sh`, Ansible, chezmoi, and mise.

This separation keeps responsibilities clean.

## Avoid `curl | bash` inside WSL

Bad:

```powershell
wsl -- bash -c "curl -sL https://example.com/install.sh | bash"
```

Problems:

- hides what is being executed
- bad for debugging
- no local copy
- no easy retry
- no verification
- no repo context
- first-run WSL may not be ready

Preferred:

```powershell
wsl -d Ubuntu-24.04 -- bash -lc "git clone https://github.com/YOU/dotfiles ~/.dotfiles || true"
wsl -d Ubuntu-24.04 -- bash -lc "cd ~/.dotfiles && bash install.sh"
```

## Terminal settings

Do not blindly overwrite Windows Terminal settings.

Correct behavior:

```text
1. Locate settings.json.
2. Backup existing file.
3. Apply minimal patch.
4. Preserve existing profiles when possible.
5. Set Ubuntu profile default only if requested.
```

## Fonts

Install a Nerd Font because terminal glyphs are required for:

- starship
- LazyVim icons
- file icons
- k9s icons
- tmux status
- modern CLI tools

Recommended candidates:

| Font | Reason |
|---|---|
| JetBrainsMono Nerd Font | Excellent coding readability |
| FiraCode Nerd Font | Ligature-friendly |
| FiraMono Nerd Font | Matches original plan |
| Hack Nerd Font | Classic terminal font |

Final recommendation:

```text
Default to JetBrainsMono Nerd Font unless there is a specific preference for FiraMono.
Make the font configurable.
```

---

# Phase 2: Minimal Linux Bootstrap

File:

```text
install.sh
```

## Purpose

Act as the explicit conductor.

## Responsibilities

`install.sh` should:

1. Enable strict mode.
2. Detect environment.
3. Install base dependencies.
4. Install verified `chezmoi`.
5. Initialize/apply dotfiles.
6. Install or invoke Ansible.
7. Run Ansible baseline.
8. Install verified `mise`.
9. Run `mise install`.
10. Generate SSH key if missing.
11. Run `doctor.sh`.

## Strict mode

Use:

```bash
set -euo pipefail
```

Why:

- `-e`: exit on failed command
- `-u`: error on unset variables
- `-o pipefail`: fail if any command in a pipeline fails

## Environment detection

The script should detect:

```text
OS_FAMILY=debian|arch|unknown
DISTRO=ubuntu|arch|unknown
ENV_KIND=wsl|native|container|github-actions
HAS_SYSTEMD=true|false
HAS_SUDO=true|false
ARCH=x86_64|arm64
```

## Why detection is mandatory

Because the same operation differs by environment.

Example:

```text
systemctl enable docker
```

Works on native systemd Linux.

May fail in:

- some WSL setups
- containers
- GitHub Actions
- minimal cloud images

## Base packages

### Ubuntu/Debian

```text
sudo
ca-certificates
curl
wget
git
gnupg
unzip
tar
gzip
xz-utils
python3
python3-pip
openssh-client
```

### Arch

```text
base-devel
ca-certificates
curl
wget
git
gnupg
unzip
tar
gzip
xz
python
python-pip
openssh
```

## Why these packages?

| Package | Why |
|---|---|
| `sudo` | privilege escalation |
| `ca-certificates` | HTTPS downloads |
| `curl`/`wget` | fetching installers/checksums |
| `git` | clone dotfiles |
| `gnupg` | signature verification |
| `unzip`/`tar`/`gzip`/`xz` | release artifact extraction |
| `python3` | Ansible and scripts |
| `pip` | Python tooling fallback |
| `openssh-client` | SSH access and key management |

---

# Phase 3: Chezmoi Dotfile Rendering

## Purpose

Render user configuration into the home directory.

## Managed files

Chezmoi should manage:

```text
~/.zshrc
~/.tmux.conf
~/.gitconfig
~/.gitconfig-personal
~/.gitconfig-work
~/.config/nvim
~/.config/starship.toml
~/.config/kitty
~/.config/mise/config.toml
~/.ssh/config
```

## Not managed by default

Chezmoi should not automatically restore:

```text
~/.ssh/id_rsa
~/.ssh/id_ed25519
~/.aws/credentials
~/.config/gcloud/application_default_credentials.json
~/.kube/config
age identities
SOPS keys
production secrets
client credentials
```

## Why not?

Because config and secrets have different risk profiles.

A bad `.zshrc` is annoying. A bad secret template can leak or corrupt sensitive material.

## Chezmoi template policy

Templates are allowed for:

- git identity
- host-specific settings
- OS-specific shell paths
- optional tool paths
- non-sensitive config

Templates must be careful with:

- secrets
- file permissions
- default values
- missing environment variables

## Git config structure

Recommended:

```gitconfig
[includeIf "gitdir:~/work/"]
  path = ~/.gitconfig-work

[includeIf "gitdir:~/personal/"]
  path = ~/.gitconfig-personal

[init]
  defaultBranch = main

[push]
  autoSetupRemote = true

[rerere]
  enabled = true
```

## Why `includeIf`?

Because you need clean separation between:

- work email
- personal email
- signing keys
- credential helpers
- repository behavior

This prevents accidental commits with the wrong identity.

---

# Phase 4: Ansible OS Baseline

## Purpose

Make the host OS usable and consistent.

## Why Ansible?

Ansible is strong for:

- package installation
- distro-specific variables
- idempotency
- service management
- conditional execution
- readable output
- role organization

## Role layout

```text
ansible/
  site.yml
  inventory.ini
  group_vars/
    all.yml
    ubuntu.yml
    arch.yml
    wsl.yml
  roles/
    common/
    shell/
    fonts/
    docker/
    podman/
    wsl/
    ubuntu/
    arch/
    cli_tools/
```

## Role responsibilities

### `common`

Installs universal packages and creates common directories.

### `shell`

Installs and configures:

- zsh
- starship prerequisites
- fzf
- zoxide
- atuin if installed through OS package

### `fonts`

Installs font packages and refreshes font cache:

```bash
fc-cache -fv
```

### `docker`

Installs Docker where appropriate.

### `podman`

Installs Podman where preferred.

### `wsl`

Handles WSL-specific behavior:

- skip unsupported service operations
- avoid assuming full init system
- handle WSL paths
- maybe integrate with Windows host conventions

### `ubuntu`

Handles apt-specific packages.

### `arch`

Handles pacman-specific packages.

### `cli_tools`

Installs OS-level tools not handled by mise.

## Callback plugins

Use Ansible output enhancements:

```text
profile_tasks
yaml callback
```

Why:

- `profile_tasks` shows slow tasks
- YAML callback improves readability
- timing table helps benchmark bootstrap

## Important rule

Ansible should not manage language runtime versions if mise owns them.

---

# Phase 5: Mise Toolchain

## Purpose

Install user-space developer runtimes and CLIs reproducibly.

## Why mise?

Mise is useful because apt/pacman versions are not always acceptable for development tooling.

It gives:

- one config file
- reproducible versions
- parallel installs
- per-project overrides
- consistent runtime management

## Recommended config

```toml
[tools]
python = "3.12"
node = "lts"
go = "1.23"
uv = "latest"
pipx = "latest"

terraform = "1.10"
kubectl = "1.31"
helm = "3"
k9s = "latest"

jq = "latest"
yq = "latest"
lazygit = "latest"
lazydocker = "latest"
eza = "latest"
zoxide = "latest"
atuin = "latest"
```

## Versioning policy

| Tool type | Policy |
|---|---|
| Shell niceties | `latest` acceptable |
| Terraform | pin exact or minor |
| kubectl | pin near target cluster versions |
| Helm | major pin acceptable |
| Python | explicit version |
| Node | LTS |
| Go | stable known version |
| Cloud CLIs | maybe official installer instead |

## Why not use `latest` everywhere?

Because infrastructure tools can break workflows.

Example risks:

- Terraform behavior changes
- provider compatibility changes
- kubectl version skew
- Node major version changes
- Python package compatibility changes

For work/client operations, stability matters more than novelty.

---

# Phase 6: Optional Secrets

## Purpose

Apply private material only after explicit unlock.

## Commands

```bash
make unlock-secrets
make apply-secrets
make restore-ssh-key
make rotate-secrets
```

## Bitwarden session model

Bitwarden requires an authenticated session.

Typical flow:

```bash
bw login
export BW_SESSION="$(bw unlock --raw)"
```

But the system should not assume this exists.

## Wrapper script

Create:

```text
scripts/bw-get.sh
```

Installed or symlinked to:

```text
~/.local/bin/bw-get
```

Behavior:

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${BW_SESSION:-}" ]]; then
  echo "BW_SESSION is not set. Run: export BW_SESSION=\$(bw unlock --raw)" >&2
  exit 1
fi

bw get item "$1"
```

## Why use wrapper instead of raw `bw` in templates?

Because templates should fail clearly.

Raw `bw` calls can produce confusing failures or empty values.

## Atomic secret writes

Secret files should be written as:

```text
1. write to temporary file
2. chmod correct permissions
3. validate non-empty content
4. move into final place atomically
```

## Permissions

| Path | Permission |
|---|---|
| `~/.ssh` | `700` |
| private key | `600` |
| public key | `644` |
| cloud credentials | `600` |
| kubeconfig | `600` or stricter |

---

# Phase 7: Validation and Doctor

## Purpose

Prove that the system actually works.

## Why this matters

A bootstrap can appear successful while leaving:

- broken shell startup
- missing PATH entries
- unusable mise shims
- bad git identity
- missing SSH key
- failed font cache
- broken nvim config
- missing Docker access

## `make doctor`

Should run:

```bash
bash scripts/doctor.sh
```

## Required checks

```text
OS detected correctly
environment detected correctly
chezmoi installed
chezmoi source exists
chezmoi apply works
git identity works
zsh exists
tmux exists
nvim exists
starship exists
mise exists
mise doctor passes
core tools are installed
SSH key exists
Bitwarden installed, if secret mode
BW_SESSION present, if secret mode
Docker available, if expected
font cache updated, if Linux GUI/WSL
```

## Smoke tests

```bash
zsh -i -c 'echo shell-ok'
tmux -V
nvim --headless '+q'
mise doctor
chezmoi diff
```

## Severity levels

Doctor output should classify failures:

| Level | Meaning |
|---|---|
| PASS | OK |
| WARN | Optional or non-blocking issue |
| FAIL | Required feature broken |
| SKIP | Not applicable in current environment |

Example:

```text
[PASS] OS detected: ubuntu
[PASS] Environment: wsl
[PASS] zsh installed
[WARN] Bitwarden session not found; secret mode unavailable
[SKIP] Docker service check skipped in CI container
[FAIL] mise not found in PATH
```

---

# Phase 8: Day-2 Operations

## Purpose

Give one cockpit for maintenance.

File:

```text
Makefile
```

## Commands

| Command | Purpose |
|---|---|
| `make bootstrap` | Run full bootstrap |
| `make apply` | Run `chezmoi apply` |
| `make diff` | Show `chezmoi diff` |
| `make update` | Pull repo, apply chezmoi, update mise tools |
| `make ansible` | Run Ansible playbook |
| `make mise` | Run `mise install` |
| `make doctor` | Validate machine state |
| `make unlock-secrets` | Guide Bitwarden login/unlock |
| `make apply-secrets` | Apply secret-backed templates |
| `make restore-ssh-key` | Explicit emergency SSH restore |
| `make backup` | Create local encrypted backup |
| `make test` | Run local test suite |
| `make uninstall-plan` | Preview cleanup |
| `make uninstall` | Safe cleanup |
| `make purge` | Dangerous full removal with confirmation |

## Why Makefile?

Because it gives a simple interface:

```bash
make doctor
make update
make diff
```

You do not need to remember exact underlying commands.

## Uninstall safety

Never make `make uninstall` immediately destructive.

Better:

```bash
make uninstall-plan
make uninstall
make purge
```

`purge` should require explicit confirmation.

---

# CI/CD and Reliability Testing

## Purpose

CI proves the repo works from a clean environment.

## Matrix

```text
ubuntu-latest
ubuntu:24.04 container
archlinux container
```

## Tests

CI should run:

```bash
bash install.sh --ci
chezmoi apply
chezmoi diff --exit-code
ansible-playbook ansible/site.yml
bash scripts/doctor.sh
zsh -i -c 'echo shell-ok'
nvim --headless '+q'
mise doctor
```

## Idempotency tests

Run important tasks twice.

Example:

```bash
chezmoi apply
chezmoi apply
chezmoi diff --exit-code
```

Ansible:

```bash
ansible-playbook ansible/site.yml
ansible-playbook ansible/site.yml
```

Second run should ideally report minimal changes.

## Why second-run testing matters

A script that only works once is not idempotent.

Idempotency proves:

- no repeated appends
- no duplicate config blocks
- no broken symlinks
- no destructive overwrites
- no repeated downloads when unnecessary

---

# Security Model

## Core principle

```text
The public dotfiles repo should be safe to clone, inspect, and run in basic mode.
```

## Threats

| Threat | Mitigation |
|---|---|
| Compromised release binary | checksum/signature verification |
| Leaked private SSH key | per-machine keys by default |
| Bad secret template | optional explicit secret phase |
| Accidental cloud credential overwrite | do not manage by default |
| Wrong git identity | includeIf split |
| Broken Bitwarden session | fail clearly |
| One device compromise | avoid shared private key |
| Dangerous uninstall | preview and confirmation |
| WSL assumptions | environment detection |
| Supply-chain script injection | avoid `curl | bash` where possible |

## Secret principle

```text
No secrets should be required for basic bootstrap.
No secret should be silently written.
No secret should be written without permission validation.
```

---

# Secret Handling Model

## Secret categories

### Category 1: Normal config

Safe for repo:

- `.zshrc`
- `.tmux.conf`
- `starship.toml`
- `nvim` config
- git aliases
- shell aliases

### Category 2: Sensitive but reconstructable

Usually not stored as secrets:

- generated SSH public keys
- known_hosts
- local machine hostname
- non-sensitive git identity

### Category 3: Private credentials

Do not auto-restore by default:

- SSH private keys
- cloud credentials
- kubeconfigs
- age identities
- production tokens
- client secrets

### Category 4: Glass-break material

Must be encrypted and physically protected:

- age master key
- Bitwarden recovery material
- emergency SSH keys
- encrypted vault export

## Why classify secrets?

Because different data needs different handling.

A `.zshrc` mistake is annoying. A leaked kubeconfig can be a serious incident.

---

# SSH Key Strategy

## Default

Generate a per-machine `ed25519` key.

```bash
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)-$(date +%Y%m%d)" -f ~/.ssh/id_ed25519
```

## Why `ed25519`?

- modern
- short keys
- strong security
- widely supported
- better default than old RSA keys for most use cases

## Why not `id_rsa` by default?

RSA is still supported but not the ideal default for new personal keys.

Existing `id_rsa` can be restored manually if needed.

## Public key output

After generating a key, print:

```bash
cat ~/.ssh/id_ed25519.pub
```

Then add it manually to:

- GitHub
- GitLab
- servers
- cloud VMs
- internal systems

## Restore command

Only restore old private keys with:

```bash
make restore-ssh-key
```

This command should:

- require Bitwarden unlock
- warn the user
- write atomically
- set permissions
- not overwrite without backup

---

# Binary Download Verification

## Rule

Any downloaded executable binary must be verified.

## Minimum acceptable verification

```text
SHA256 checksum verification
```

## Better verification

```text
GPG signature
cosign signature
official package repository
```

## Applies to

- chezmoi
- Bitwarden CLI
- mise
- age
- sops
- other standalone release binaries

## Why this matters

Direct GitHub release downloads are convenient but not automatically safe.

A compromised download path, wrong URL, or release tampering could install a malicious binary.

## Helper script

Create:

```text
scripts/verify-download.sh
```

Expected behavior:

```text
download artifact
download checksum
compare SHA256
install only if verified
```

---

# Windows and WSL Design Notes

## WSL first-run problem

A newly installed WSL distro may require first-run initialization.

Therefore `install.ps1` must not assume:

```text
Ubuntu is instantly ready
default user exists
network is ready
bash command works immediately
```

## Distro name

Do not assume:

```text
Ubuntu
```

Use explicit:

```text
Ubuntu-24.04
```

where possible.

## WSL and systemd

Modern WSL can support systemd, but not every environment will have it enabled.

Detect:

```bash
ps -p 1 -o comm=
```

If PID 1 is `systemd`, service management is possible. Otherwise skip or warn.

## Docker in WSL

Possible options:

1. Docker Desktop integration
2. native Docker Engine inside WSL
3. Podman
4. remote Docker context

Default should not blindly install Docker Engine in WSL.

---

# Linux Distribution Design Notes

## Ubuntu

Use apt for baseline system packages.

Good target:

```text
Ubuntu 24.04
```

Why:

- modern packages
- stable
- WSL support
- cloud VM availability
- common enterprise target

## Arch

Use pacman for baseline packages.

Arch requires extra attention because:

- package names differ
- rolling release behavior changes
- service defaults differ
- AUR should not be assumed in base bootstrap

## Containers

Containers should skip:

- service enablement
- systemd assumptions
- GUI font behavior if irrelevant
- Docker daemon setup

CI containers are for smoke tests, not full machine simulation.

---

# Docker and Podman Strategy

## Problem

Docker installation is environment-sensitive.

## Final policy

Do not blindly install and enable Docker everywhere.

## Recommended behavior

| Environment | Default |
|---|---|
| Native Ubuntu | Docker Engine |
| Arch laptop | Docker or Podman depending preference |
| Windows + WSL | Prefer Docker Desktop integration unless native explicitly requested |
| CI container | Skip daemon setup |
| Cloud VM | Docker Engine if needed |
| Minimal container | Skip |

## Why both Docker and Podman may be too much

Installing both everywhere can create:

- duplicate tooling
- socket confusion
- rootless vs rootful ambiguity
- unnecessary packages

Default should be based on machine type.

---

# Cloud CLI Strategy

## Tools

- `gcloud`
- `aws-cli`
- `azure-cli`

## Challenge

Cloud CLIs are large and sometimes have special installation/update requirements.

## Policy

| Tool | Preferred approach |
|---|---|
| `gcloud` | official package repo or mise if reliable |
| `aws-cli` | official installer or mise if reliable |
| `azure-cli` | official package repo often better |
| `kubectl` | mise or official release |
| `helm` | mise or package repo |
| `terraform` | mise with pinned version |

## Why not force all through mise?

Because mise is excellent, but not every plugin has the same reliability level.

For client work, reliability matters more than theoretical neatness.

---

# Git Identity Strategy

## Problem

You need different identities for work and personal repositories.

## Solution

Use `includeIf`.

```gitconfig
[includeIf "gitdir:~/work/"]
  path = ~/.gitconfig-work

[includeIf "gitdir:~/personal/"]
  path = ~/.gitconfig-personal
```

## Why this matters

Prevents:

- committing to work with personal email
- committing to personal repos with work email
- signing with wrong key
- confusing credential helpers

## Recommended directory convention

```text
~/work/
~/personal/
~/lab/
~/src/
```

`~/work` and `~/personal` have explicit git identities.

`~/lab` can inherit default or use a neutral identity.

---

# Shell Strategy

## Recommended stack

- zsh
- starship
- zoxide
- fzf
- atuin
- eza
- bat
- ripgrep
- fd
- tmux

## Oh My Zsh decision

Oh My Zsh is optional.

### Pros

- easy plugin ecosystem
- familiar
- lots of themes/plugins

### Cons

- startup overhead
- plugin drift
- unnecessary complexity if using starship/fzf/zoxide
- more moving pieces

## Final recommendation

Use lean zsh by default.

Optional Oh My Zsh support can be added behind a flag.

---

# Editor Strategy

## Recommended editor

Neovim with LazyVim.

## Why

Fits the user's terminal-first workflow and DevOps/cloud focus.

Useful for:

- Terraform
- YAML
- Helm
- Kubernetes manifests
- Go
- Python
- TypeScript/JavaScript
- Markdown
- JSON
- shell scripts

## CI smoke test

Run:

```bash
nvim --headless '+q'
```

Potentially also:

```bash
nvim --headless '+Lazy! sync' +qa
```

But plugin sync in CI can be flaky. Treat it carefully.

---

# Terminal and Font Strategy

## Windows Terminal

Use Windows Terminal on host.

## Kitty

Use Kitty where appropriate:

- native Linux
- WSLg
- Linux desktop

Do not assume Kitty is useful on headless servers.

## Font choice

Default recommendation:

```text
JetBrainsMono Nerd Font
```

Reason:

- readable
- popular among terminal users
- good glyph support
- strong coding ergonomics

Make configurable.

## Font cache

On Linux GUI/WSL:

```bash
fc-cache -fv
```

Skip or warn in headless/minimal environments if not relevant.

---

# Backup and Glass-Break Plan

## Original risk

Putting all of this together is dangerous:

```text
age master key
SSH private keys
Bitwarden recovery key
```

If one physical bundle is compromised, everything may be compromised.

## Revised model

Split recovery material.

## Paper backup

Contains:

```text
Bitwarden recovery code
emergency instructions
where encrypted USB is stored
where offsite backup is stored
```

## Encrypted USB

Contains:

```text
age identity, encrypted
selected SSH private keys, encrypted
dotfiles repo snapshot
recovery instructions
possibly encrypted Bitwarden export
```

## Offsite encrypted backup

Contains:

```text
age-encrypted backup archive
dotfiles snapshot
critical public keys
```

## Rule

```text
No raw private keys sitting unencrypted on the drive.
No single physical object should contain everything needed to compromise everything.
```

---

# Failure Modes and Mitigations

## Bitwarden session missing

### Symptom

Secret templates fail.

### Mitigation

Secrets are optional. Basic bootstrap continues.

Doctor shows:

```text
[WARN] BW_SESSION is not set; secret mode unavailable
```

## WSL not ready

### Symptom

PowerShell handoff fails.

### Mitigation

Retry WSL startup, verify distro exists, avoid immediate assumptions.

## Wrong package manager

### Symptom

Install fails on unsupported distro.

### Mitigation

Detect `apt` or `pacman`. Unknown distro fails clearly.

## Docker service unavailable

### Symptom

`systemctl` fails.

### Mitigation

Check systemd before service operations.

## Mise tool install fails

### Symptom

Some CLI not installed.

### Mitigation

Pin versions and allow retry. Doctor reports missing tool.

## Chezmoi template error

### Symptom

`chezmoi apply` fails.

### Mitigation

Use `chezmoi diff`, clear templates, avoid secrets in basic phase.

## Bad terminal settings merge

### Symptom

Windows Terminal config broken.

### Mitigation

Backup before mutation.

## Private key overwrite

### Symptom

Existing SSH key replaced.

### Mitigation

Never overwrite without backup and explicit confirmation.

---

# Makefile Contract

Example structure:

```makefile
.PHONY: bootstrap apply diff update ansible mise doctor unlock-secrets apply-secrets restore-ssh-key backup test uninstall-plan uninstall purge

bootstrap:
	bash install.sh

apply:
	chezmoi apply

diff:
	chezmoi diff

update:
	git pull --ff-only
	chezmoi apply
	mise install
	mise upgrade

ansible:
	ansible-playbook ansible/site.yml

mise:
	mise install

doctor:
	bash scripts/doctor.sh

unlock-secrets:
	@echo 'Run: export BW_SESSION=$$(bw unlock --raw)'

apply-secrets:
	bash scripts/apply-secrets.sh

restore-ssh-key:
	bash scripts/restore-ssh-key.sh

backup:
	bash scripts/backup.sh

test:
	bash tests/test-idempotency.sh
	bash tests/test-shell.sh
	bash tests/test-mise.sh

uninstall-plan:
	chezmoi diff

uninstall:
	@echo "Safe uninstall should backup before removing managed files."

purge:
	@echo "Dangerous. Require explicit confirmation."
```

---

# Doctor Script Contract

## Inputs

Optional flags:

```text
--ci
--secret
--verbose
--json
```

## Output

Human-readable default.

Optional JSON for automation.

## Required checks

```text
command_exists git
command_exists chezmoi
command_exists zsh
command_exists tmux
command_exists nvim
command_exists mise
check_git_identity
check_ssh_key
check_mise_doctor
check_shell_startup
check_chezmoi_diff
check_docker_if_expected
check_bw_if_secret_mode
```

## Exit codes

| Exit Code | Meaning |
|---:|---|
| 0 | all required checks passed |
| 1 | required check failed |
| 2 | invalid usage |
| 3 | unsupported environment |

---

# Install Script Contract

## Flags

Recommended:

```text
--ci
--no-ansible
--no-mise
--no-secrets
--with-secrets
--dry-run
--verbose
```

## Behavior

Default:

```text
basic bootstrap only
no secret restore
interactive where appropriate
```

CI:

```text
no secrets
no destructive system changes
skip service operations where needed
```

Secret mode:

```text
requires BW_SESSION
applies secret-backed material
```

## Important invariant

```text
install.sh should be safe to re-run.
```

---

# Ansible Role Contract

## Requirements

Each role should:

- be idempotent
- use distro variables
- avoid hardcoded assumptions
- skip unsupported environments
- expose useful tags

## Suggested tags

```text
common
shell
fonts
docker
podman
wsl
ubuntu
arch
cli
```

Run examples:

```bash
ansible-playbook ansible/site.yml --tags shell
ansible-playbook ansible/site.yml --tags docker
```

## Idempotency

Second run should produce minimal changes.

If a task always changes, document why.

---

# Mise Config Contract

## Location

```text
~/.config/mise/config.toml
```

Managed by chezmoi.

## Policy

Use stable versions for important infrastructure tools.

Use latest only for low-risk utility CLIs.

## Example

```toml
[tools]
python = "3.12"
node = "lts"
go = "1.23"
terraform = "1.10"
kubectl = "1.31"
helm = "3"
uv = "latest"
jq = "latest"
yq = "latest"
lazygit = "latest"
```

---

# Chezmoi Contract

## Basic mode

Chezmoi applies:

- shell config
- editor config
- git config
- tmux config
- mise config
- terminal config
- SSH config

## Secret mode

Secret-backed files are explicit.

Recommended:

```bash
chezmoi apply --include encrypted
```

or separate script:

```bash
make apply-secrets
```

## Safety

Templates must:

- not silently write empty secret values
- fail clearly
- use default values for non-sensitive config
- avoid destructive overwrites

---

# Detailed Architecture Decision Records

## ADR-0001: Secrets are optional

### Context

The original plan required Bitwarden during bootstrap.

### Decision

Secrets are optional. Basic bootstrap requires no vault.

### Consequences

Positive:

- CI works
- recovery works
- fresh machine setup is easier
- less fragile

Negative:

- secret setup requires a second command
- some manual steps remain

### Final verdict

Accepted.

---

## ADR-0002: `install.sh` is the conductor

### Context

Chezmoi can run scripts, but hidden scripts can become hard to debug.

### Decision

`install.sh` explicitly orchestrates all major phases.

### Consequences

Positive:

- clear logs
- easier debugging
- obvious flow
- better CI control

Negative:

- install script becomes more important
- must keep it clean

### Final verdict

Accepted.

---

## ADR-0003: Per-machine SSH keys

### Context

Restoring the same private SSH key everywhere is convenient.

### Decision

Generate a new `ed25519` key per machine by default.

### Consequences

Positive:

- reduced blast radius
- easier revocation
- better auditability

Negative:

- manual public key registration required
- more keys to manage

### Final verdict

Accepted.

---

## ADR-0004: Verified binary downloads

### Context

Direct downloads from GitHub releases are convenient but not enough.

### Decision

Verify checksums or signatures for downloaded binaries.

### Consequences

Positive:

- better supply-chain security
- safer bootstrap

Negative:

- more code
- more maintenance when release formats change

### Final verdict

Accepted.

---

## ADR-0005: Ansible for OS baseline

### Context

Bash can install packages but grows messy across OSes.

### Decision

Use Ansible roles for OS-level state.

### Consequences

Positive:

- idempotency
- clean distro branching
- better output
- role reuse

Negative:

- adds dependency
- requires Ansible knowledge

### Final verdict

Accepted.

---

## ADR-0006: Mise for toolchains

### Context

Apt/pacman tool versions drift and may be old.

### Decision

Use mise for runtimes and user-space CLIs.

### Consequences

Positive:

- reproducible versions
- cleaner runtime management
- one config file

Negative:

- plugin reliability varies
- not all CLIs belong there

### Final verdict

Accepted.

---

## ADR-0007: Lean zsh over mandatory Oh My Zsh

### Context

Oh My Zsh is popular but can add startup overhead and plugin drift.

### Decision

Use lean zsh plus starship/fzf/zoxide/atuin by default. Make Oh My Zsh optional.

### Consequences

Positive:

- faster startup
- less magic
- easier debugging

Negative:

- fewer ready-made plugins

### Final verdict

Accepted.

---

## ADR-0008: Do not blindly install Docker everywhere

### Context

Docker setup differs between WSL, native Linux, CI, and servers.

### Decision

Detect environment and choose behavior.

### Consequences

Positive:

- fewer broken installs
- cleaner WSL behavior
- CI does not fail on service setup

Negative:

- more conditional logic

### Final verdict

Accepted.

---

## ADR-0009: CI validates usability

### Context

Exit-code-only CI does not prove a usable environment.

### Decision

CI runs shell, editor, mise, chezmoi, Ansible, and doctor smoke tests.

### Consequences

Positive:

- catches real failures
- proves idempotency
- improves trust

Negative:

- CI takes longer
- tests require maintenance

### Final verdict

Accepted.

---

## ADR-0010: Split glass-break material

### Context

A single drive containing all secrets is risky.

### Decision

Split recovery across paper, encrypted USB, and offsite encrypted backup.

### Consequences

Positive:

- reduces single-object compromise risk
- improves recoverability

Negative:

- more complex recovery process

### Final verdict

Accepted.

---

# Implementation Checklist

## Stage 1: Foundation

- [ ] Create repo structure
- [ ] Add `README.md`
- [ ] Add `docs/DESIGN.md`
- [ ] Add `docs/BOOTSTRAP.md`
- [ ] Add `docs/SECURITY.md`
- [ ] Add `docs/RECOVERY.md`
- [ ] Add `install.sh`
- [ ] Add `install.ps1`
- [ ] Add `Makefile`

## Stage 2: Detection

- [ ] Implement `scripts/detect-env.sh`
- [ ] Detect apt/pacman
- [ ] Detect WSL
- [ ] Detect container
- [ ] Detect GitHub Actions
- [ ] Detect systemd
- [ ] Detect architecture

## Stage 3: Minimal Bootstrap

- [ ] Install base packages on Ubuntu
- [ ] Install base packages on Arch
- [ ] Install verified chezmoi
- [ ] Clone/init dotfiles
- [ ] Run `chezmoi apply`

## Stage 4: Chezmoi

- [ ] Add zsh config
- [ ] Add tmux config
- [ ] Add gitconfig templates
- [ ] Add nvim config
- [ ] Add starship config
- [ ] Add mise config
- [ ] Add SSH config only, not private keys

## Stage 5: Ansible

- [ ] Add inventory
- [ ] Add group vars
- [ ] Add common role
- [ ] Add shell role
- [ ] Add fonts role
- [ ] Add Ubuntu role
- [ ] Add Arch role
- [ ] Add WSL role
- [ ] Add Docker role with environment detection
- [ ] Add Podman role if desired

## Stage 6: Mise

- [ ] Install mise
- [ ] Add global config
- [ ] Install pinned runtimes
- [ ] Install low-risk latest utilities
- [ ] Run `mise doctor`

## Stage 7: Secrets

- [ ] Install Bitwarden CLI with verification
- [ ] Add `bw-get.sh`
- [ ] Add `make unlock-secrets`
- [ ] Add `make apply-secrets`
- [ ] Add `make restore-ssh-key`
- [ ] Enforce permissions
- [ ] Use atomic writes

## Stage 8: Doctor

- [ ] Add required checks
- [ ] Add optional checks
- [ ] Add secret mode checks
- [ ] Add Docker checks
- [ ] Add shell startup check
- [ ] Add nvim headless check
- [ ] Add mise doctor check

## Stage 9: CI

- [ ] Add GitHub Actions workflow
- [ ] Test Ubuntu
- [ ] Test Arch container
- [ ] Test idempotency
- [ ] Test shell startup
- [ ] Test nvim headless
- [ ] Test mise
- [ ] Test doctor

## Stage 10: Recovery

- [ ] Write recovery instructions
- [ ] Create encrypted USB process
- [ ] Create offsite encrypted backup process
- [ ] Document key rotation
- [ ] Document lost-machine procedure

---

# Final Review

This design is strong because it respects reality.

It does not pretend that:

- WSL behaves exactly like native Linux
- containers behave like real machines
- Bitwarden is always available
- private SSH key restore is harmless
- latest versions are always safe
- downloaded binaries are automatically trustworthy
- CI success means the shell is usable
- one bootstrap path fits every environment

Instead, it creates a layered system with explicit contracts.

## Final strengths

| Area | Strength |
|---|---|
| Reliability | Basic bootstrap works without secrets |
| Security | Per-machine SSH keys and verified downloads |
| Debuggability | `install.sh` is explicit conductor |
| Maintainability | Clear repo layout and role boundaries |
| Idempotency | CI and doctor validate repeated runs |
| Portability | Environment detection handles WSL/native/container |
| Recovery | Glass-break material is split and encrypted |
| Day-2 usability | Makefile cockpit keeps operations simple |

## Remaining risks

| Risk | Mitigation |
|---|---|
| Cross-platform complexity | Define support levels clearly |
| Mise plugin reliability | Pin or use official installers |
| Cloud CLI weirdness | Use official repos where better |
| Ansible drift | Test second-run idempotency |
| Secret restore danger | Keep explicit and permission-checked |
| Windows Terminal schema changes | Backup and patch minimally |

## Final conclusion

This is now a production-quality personal dotfiles/bootstrap architecture.

It is not overengineered for your use case because your actual workflow spans:

- Windows
- WSL
- Ubuntu
- Arch
- cloud VMs
- old laptops
- terminal-first development
- Kubernetes/cloud tooling
- secrets
- personal vault integration
- CI validation
- long-running agent/devops workflows

The final architecture earns:

```text
9.1/10
```

The strongest principle remains:

```text
Bootstrap should make the machine useful first.
Secrets should be explicit, optional, and controlled.
```
