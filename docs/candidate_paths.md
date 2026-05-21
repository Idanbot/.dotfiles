# Candidate Paths for Dotfiles and Workflow Discovery

## Purpose

This document lists system and user paths that may contain configuration, setup scripts, workflow helpers, package choices, or environment assumptions relevant to this dotfiles project.

It is an inventory plan only. It does not imply these files should be read, copied, or committed.

## Safety Policy

Discovery should happen in two stages:

1. Inventory metadata only: path, file type, size, modified time, ownership, and whether the file exists.
2. Content review only after secret scanning and explicit approval.

Do not read or import content from high-risk files during initial inventory.

Never commit:

- Tokens, API keys, passwords, cookies, sessions, or private keys.
- `CF_TOKEN` or any Cloudflare token.
- SSH private keys.
- Cloud credentials.
- Kubeconfigs.
- Age, SOPS, GPG, or Bitwarden secret material.
- Client names, internal domains, private hostnames, or private network aliases unless explicitly approved.

## Risk Levels

| Level | Meaning | Default Handling |
|---|---|---|
| Low | Usually safe configuration or public workflow metadata | Inventory, then content scan before import |
| Medium | May contain private paths, aliases, hostnames, emails, or machine-specific state | Inventory only, then review selectively |
| High | Likely to contain credentials, tokens, private keys, or sensitive infrastructure details | Inventory metadata only; content requires explicit approval |
| Excluded | Should not be scanned for this project | Skip |

## Home Shell and Terminal

| Path | Relevance | Risk | Notes |
|---|---|---:|---|
| `~/.zshrc` | Primary interactive shell config | High | Known possible `CF_TOKEN`; do not import before gitleaks exists |
| `~/.zprofile` | Login shell setup | Medium | May contain PATH and environment setup |
| `~/.zlogin` | Login shell commands | Medium | May contain machine-specific logic |
| `~/.zshenv` | Global zsh environment | High | Can contain exported secrets |
| `~/.zlogout` | Shell logout behavior | Low | Usually low value |
| `~/.zsh/` | Functions, plugins, completion, aliases | High | May contain private aliases or tokens |
| `~/.oh-my-zsh/` | Oh My Zsh install and customizations | Medium | Inventory plugins and custom files; do not vendor full framework |
| `~/.oh-my-zsh/custom/` | Custom plugins/themes | Medium | Good source for curated shell behavior |
| `~/.bashrc` | Bash fallback config | Medium | May contain duplicated shell logic |
| `~/.profile` | POSIX login environment | Medium | PATH and environment setup |
| `~/.tmux.conf` | tmux config | Medium | Strong candidate for chezmoi after scanning |
| `~/.tmux/` | tmux plugins/scripts | Medium | Inventory plugin manager and custom scripts |
| `~/.config/starship.toml` | Prompt config | Low | Good chezmoi candidate |
| `~/.config/kitty/` | Kitty terminal config | Medium | May contain host-specific settings |
| `~/.config/alacritty/` | Alacritty terminal config | Low | Candidate if used |
| `~/.config/wezterm/` | WezTerm config | Medium | Lua config may include paths or hostnames |

## Editor and Development Environment

| Path | Relevance | Risk | Notes |
|---|---|---:|---|
| `~/.config/nvim/` | Neovim/LazyVim config | Medium | Strong v1 candidate; scan before import |
| `~/.local/share/nvim/` | Neovim plugin data | Excluded | Generated state; do not commit |
| `~/.local/state/nvim/` | Neovim state | Excluded | Generated state |
| `~/.cache/nvim/` | Neovim cache | Excluded | Generated state |
| `~/.vimrc` | Vim config | Low | Candidate if still relevant |
| `~/.vim/` | Vim plugins/config | Medium | Avoid generated plugin directories |
| `~/.config/Code/User/settings.json` | VS Code settings | Medium | May contain private paths or extensions |
| `~/.config/Code/User/keybindings.json` | VS Code keybindings | Low | Candidate if VS Code is used |
| `~/.config/Code/User/snippets/` | VS Code snippets | Medium | May contain private templates |
| `~/.vscode/extensions/` | VS Code extension installs | Excluded | Inventory extension list only if needed |

## Git, SSH, and Identity

| Path | Relevance | Risk | Notes |
|---|---|---:|---|
| `~/.gitconfig` | Git defaults and includes | Medium | Review email/name/aliases before commit |
| `~/.gitconfig-personal` | Personal Git identity | Medium | Email/name review required |
| `~/.gitconfig-work` | Work Git identity | High | Likely private; public repo review required |
| `~/.config/git/` | Git config, ignore, attributes | Medium | Good candidate after scan |
| `~/.ssh/config` | SSH host aliases | High | May expose private hosts; inventory only first |
| `~/.ssh/known_hosts` | SSH known hosts | Excluded | Do not commit |
| `~/.ssh/id_*` | SSH private/public keys | High | Private keys never committed; public keys inventory only |
| `~/.gnupg/` | GPG keys and agent config | High | Do not read key material |
| `~/.config/gh/` | GitHub CLI config | High | May include tokens; content excluded |
| `~/.config/glab-cli/` | GitLab CLI config | High | May include tokens |

## Runtime and Tool Managers

| Path | Relevance | Risk | Notes |
|---|---|---:|---|
| `~/.config/mise/` | mise config | Medium | Strong v1 candidate |
| `~/.tool-versions` | asdf/mise tool versions | Low | Candidate for migration |
| `~/.asdfrc` | asdf config | Low | Candidate if asdf was used |
| `~/.asdf/` | asdf installation/plugins | Medium | Inventory plugins only |
| `~/.config/direnv/` | direnv config | Medium | May reveal project paths |
| `~/.local/share/direnv/` | direnv allow/cache state | Excluded | Generated state |
| `~/.cargo/config.toml` | Rust cargo config | Medium | May include registries |
| `~/.npmrc` | npm config | High | Often contains tokens |
| `~/.pypirc` | Python package publishing config | High | Often contains tokens |
| `~/.pip/pip.conf` | pip config | Medium | May contain private indexes |
| `~/.config/pip/pip.conf` | pip config | Medium | May contain private indexes |
| `~/.config/pypoetry/` | Poetry config | Medium | May contain private indexes |

## CLI Tools and Workflow Apps

| Path | Relevance | Risk | Notes |
|---|---|---:|---|
| `~/.config/lazygit/` | lazygit config | Low | Candidate |
| `~/.config/lazydocker/` | lazydocker config | Low | Candidate |
| `~/.config/atuin/` | shell history sync config | High | May include sync keys or history settings |
| `~/.local/share/atuin/` | shell history database | Excluded | Do not scan/import |
| `~/.config/zoxide/` | zoxide config | Low | Usually generated; low value |
| `~/.local/share/zoxide/` | zoxide database | Excluded | Generated path history |
| `~/.config/bat/` | bat themes/config | Low | Candidate |
| `~/.config/fd/` | fd ignore/config | Low | Candidate if present |
| `~/.ripgreprc` | ripgrep defaults | Low | Candidate |
| `~/.config/yazi/` | yazi file manager config | Medium | Candidate if used |
| `~/.config/k9s/` | k9s config | High | May include cluster names/context hints |

## Cloud, Kubernetes, and Infrastructure

| Path | Relevance | Risk | Notes |
|---|---|---:|---|
| `~/.kube/config` | Kubernetes contexts | High | Do not import; may contain sensitive endpoints/tokens |
| `~/.kube/` | Kubernetes config/cache | High | Inventory only, exclude content |
| `~/.aws/config` | AWS profiles | High | May reveal accounts/regions |
| `~/.aws/credentials` | AWS credentials | High | Never read/import |
| `~/.config/gcloud/` | Google Cloud CLI config | High | Contains credentials and project data |
| `~/.azure/` | Azure CLI config | High | Contains sessions/tokens |
| `~/.oci/` | OCI CLI config and keys | High | Contains tenancy/user/key paths |
| `~/.terraformrc` | Terraform CLI config | High | May contain private registry tokens |
| `~/.terraform.d/` | Terraform credentials/plugins | High | Credentials excluded |
| `~/.config/helm/` | Helm config | Medium | May contain repo names |
| `~/.cache/helm/` | Helm cache | Excluded | Generated state |
| `~/.config/sops/` | SOPS config | High | May reference keys |
| `~/.config/age/` | age identities | High | Never read/import private identities |

## Containers and Virtualization

| Path | Relevance | Risk | Notes |
|---|---|---:|---|
| `~/.docker/config.json` | Docker auth and config | High | Often contains credential helpers/auth |
| `~/.config/containers/` | Podman/container config | Medium | Candidate after scan |
| `~/.colima/` | Colima config | Medium | Mostly macOS; likely out of v1 |
| `/etc/docker/` | Docker daemon config | Medium | System config candidate |
| `/etc/containers/` | Podman system config | Medium | Future candidate |

## User Scripts and Local Binaries

| Path | Relevance | Risk | Notes |
|---|---|---:|---|
| `~/bin/` | Personal scripts | High | Strong candidate after scanning |
| `~/.local/bin/` | User binaries/scripts | High | Inventory scripts; ignore downloaded binaries |
| `~/scripts/` | Personal scripts | High | Strong candidate after scanning |
| `~/Code/` | Development repos | Medium | Inventory repo names only unless selected |
| `~/Code/github/` | GitHub repos | Medium | Inventory relevant dotfile/tool repos |
| `~/github/` | GitHub repos | Medium | Alternative location |
| `~/work/` | Work repos | High | Avoid content unless explicitly approved |
| `~/personal/` | Personal repos | Medium | Inventory only first |
| `~/lab/` | Experiments | Medium | Inventory only first |
| `~/src/` | Source repos | Medium | Inventory only first |

## System Configuration

| Path | Relevance | Risk | Notes |
|---|---|---:|---|
| `/etc/wsl.conf` | WSL behavior | Low | Strong WSL candidate |
| `/etc/environment` | Global environment | High | May contain secrets |
| `/etc/profile` | Global shell profile | Medium | System shell behavior |
| `/etc/profile.d/` | Global shell snippets | High | May export secrets or tool paths |
| `/etc/zsh/` | System zsh config | Medium | Useful for understanding defaults |
| `/etc/bash.bashrc` | System bash config | Medium | Useful for fallback behavior |
| `/etc/gitconfig` | System Git defaults | Medium | Candidate for awareness only |
| `/etc/apt/sources.list` | Apt repositories | Medium | Useful for Ansible package strategy |
| `/etc/apt/sources.list.d/` | Apt repositories | Medium | May reveal private repos |
| `/etc/apt/keyrings/` | Apt keyrings | Medium | Inventory only |
| `/etc/systemd/system/` | System services | Medium | Inventory custom units only |
| `~/.config/systemd/user/` | User services | Medium | Candidate after scan |
| `/usr/local/bin/` | Local scripts/binaries | High | Inventory scripts; ignore binaries |
| `/usr/local/sbin/` | Local admin scripts | High | Inventory only |
| `/opt/` | Manually installed software | Medium | Inventory names only |

## WSL and Windows-Adjacent Paths

| Path | Relevance | Risk | Notes |
|---|---|---:|---|
| `/mnt/c/Users/` | Windows user profiles | High | Do not broad-scan content |
| `/mnt/c/Users/*/AppData/Local/Packages/Microsoft.WindowsTerminal_*/LocalState/settings.json` | Windows Terminal settings | Medium | Candidate with explicit approval |
| `/mnt/c/Users/*/AppData/Local/Microsoft/Windows Terminal/settings.json` | Windows Terminal settings | Medium | Candidate with explicit approval |
| `/mnt/c/Users/*/.gitconfig` | Windows Git config | Medium | Candidate with explicit approval |
| `/mnt/c/Users/*/.ssh/config` | Windows SSH config | High | Inventory only |

## Initial Inventory Command Shape

The first inventory script should collect only metadata:

```text
path
exists
type
size
modified time
owner
risk level from this document
```

It should not print file contents.

## Content Review Requirements

Before reading file contents:

- `gitleaks` must pass in the repository.
- The path must be selected from the candidate inventory.
- High-risk paths require explicit approval.
- Results should be redacted where possible.
- Imported config should be curated, not copied wholesale.

## Strong First Candidates After Security Gate

These are likely high-value after secret scanning exists:

- `~/.tmux.conf`
- `~/.config/nvim/`
- `~/.config/starship.toml`
- `~/.config/mise/`
- `~/.ripgreprc`
- `~/.config/bat/`
- `~/.gitconfig`
- `~/.zsh/functions/`
- selected safe parts of `~/.zshrc`

## Paths to Avoid by Default

- Browser profiles.
- Password manager local data.
- Shell history databases.
- SSH private keys.
- Cloud credential files.
- Kubernetes configs.
- Generated caches.
- Large package/plugin directories.
- Work repository contents unless explicitly selected.

