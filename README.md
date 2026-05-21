# 🏠 Dotfiles — Idan Botbol

> One-command bootstrap for Ubuntu 24.04 LTS (native & WSL). Managed by [chezmoi](https://chezmoi.io) with [age](https://age-encryption.org) encryption for secrets.

## ⚡ Quick Start

### Fresh Machine (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/idanbotbol/dotfiles/main/scripts/install.sh | bash
```

### Or clone and run:

```bash
git clone git@github.com:idanbotbol/dotfiles.git ~/.dotfiles
cd ~/.dotfiles && ./scripts/install.sh
```

### Existing Machine (already have chezmoi)

```bash
chezmoi init --apply idanbotbol/dotfiles --ssh
```

---

## 📦 What Gets Installed

| Category | Tools |
|----------|-------|
| **Shell** | Zsh, Oh-My-Zsh, Starship prompt, fzf-tab, zsh-autosuggestions, zsh-syntax-highlighting |
| **Terminal** | Kitty (native), Ghostty (secondary), tmux + TPM, tmuxp |
| **Editor** | Neovim (LazyVim), Vim |
| **CLI Tools** | fzf, fd, ripgrep, bat, eza, lazygit, btop, htop, jq |
| **Languages** | Go 1.24, Rust (stable), Node.js 22 (nvm), Python 3.12 (uv), Java 21 |
| **Containers** | Docker, kubectl, Helm, k9s |
| **Cloud** | AWS CLI v2, Google Cloud CLI, Azure CLI, Terraform, Ansible |
| **AI Tools** | Claude CLI, Gemini CLI, OpenCode |
| **Media** | yt-dlp, rmpc, cava (native only) |
| **Fonts** | FiraMono Nerd Font |
| **Theme** | Catppuccin Mocha (everywhere) |

---

## 📁 Repo Structure

```
~/.dotfiles/
├── scripts/install.sh            # Bootstrap entrypoint
├── .chezmoi.yaml.tmpl            # chezmoi init prompts
├── .chezmoiexternal.yaml         # External deps (oh-my-zsh, TPM, etc.)
├── .chezmoiignore                # Platform-specific ignores
├── packages.yaml                 # Version-pinned tool manifest
│
├── dot_zshrc.tmpl                # Zsh config (WSL/native templated)
├── dot_tmux.conf.tmpl            # tmux config (WSL/native templated)
├── dot_gitconfig.tmpl            # Git config (templated email)
├── dot_bashrc / dot_vimrc / ...  # Other configs
│
├── dot_config/                   # ~/.config/ files
│   ├── starship.toml             # Starship prompt
│   ├── nvim/                     # LazyVim config
│   ├── private_kitty/            # Kitty terminal
│   └── ...                       # lazygit, btop, bat, etc.
│
├── dot_local/bin/                # Custom scripts
│   ├── tmux-sessionizer.tmpl     # Project switcher
│   └── fzf-preview.sh            # FZF preview
│
├── encrypted_*                   # age-encrypted secrets
│
├── .chezmoiscripts/              # chezmoi run scripts
│   ├── run_once_before_*.sh.tmpl # Pre-apply install scripts
│   ├── run_once_*.sh.tmpl        # Install scripts
│   └── run_onchange_*.sh.tmpl    # Re-run on manifest change
│
├── scripts/lib.sh                # Shared bash utilities
├── tests/                        # CI test scripts
└── .github/workflows/            # GitHub Actions CI
```

---

## 🔧 chezmoi Workflow Cheat Sheet

| Action | Command |
|--------|--------|
| **Apply configs** | `chezmoi apply` |
| **Pull & apply latest** | `chezmoi update` |
| **Add a config file** | `chezmoi add ~/.config/tool/config` |
| **Add a secret (encrypted)** | `chezmoi add --encrypt ~/.ssh/id_ed25519` |
| **Edit a managed file** | `chezmoi edit ~/.zshrc` |
| **Preview changes** | `chezmoi diff` |
| **View managed files** | `chezmoi managed` |
| **Re-init (re-run prompts)** | `chezmoi init` |
| **Push changes** | `cd ~/.dotfiles && git add -A && git commit -m "..." && git push` |

---

## 🔐 Secret Management

Secrets are encrypted with [age](https://age-encryption.org) and stored in the repo as `encrypted_*` files.

### Encrypted Files

| File | Target |
|------|--------|
| `encrypted_dot_ssh/` | `~/.ssh/` (keys + config) |
| `encrypted_dot_gnupg/` | `~/.gnupg/` (GPG keys) |
| `encrypted_dot_git-credentials` | `~/.git-credentials` |
| `encrypted_dot_cloudflared/` | `~/.cloudflared/` |
| `encrypted_private_dot_aws/credentials` | `~/.aws/credentials` |

### Key Management

- **Identity key location**: `~/.config/chezmoi/key.txt`
- **⚠️ BACK THIS UP**: Bitwarden, encrypted USB, or another secure location
- **Generate new key**: `age-keygen -o ~/.config/chezmoi/key.txt`
- **Encrypt a new file**: `chezmoi add --encrypt <file>`

---

## 🖥️ WSL vs Native

The bootstrap auto-detects WSL by checking `/proc/version` for "microsoft".

| Feature | Native | WSL |
|---------|--------|-----|
| Kitty terminal | ✅ | ❌ |
| GNOME desktop | ✅ | ❌ |
| Docker Engine | ✅ (full) | CLI only (Docker Desktop) |
| tmux terminal | `xterm-kitty` | `tmux-256color` |
| Battery in tmux | ✅ | ❌ |
| Media tools (rmpc, cava) | ✅ | ❌ |
| Image preview in fzf | ✅ (kitty icat) | ❌ |
| All other tools | ✅ | ✅ |

---

## ➕ Adding a New Tool

1. **Update `packages.yaml`** with the version
2. **Create/update install script** in `.chezmoiscripts/run_once_*.sh.tmpl`
3. **Add config** with `chezmoi add ~/.config/newtool/config`
4. **Test**: `chezmoi apply --verbose`
5. **Commit**: `cd ~/.dotfiles && git add -A && git commit -m "Add newtool" && git push`

---

## 🎨 Theme: Catppuccin Mocha

All tools are themed with [Catppuccin Mocha](https://github.com/catppuccin/catppuccin):

- ✅ Starship prompt
- ✅ FZF colors
- ✅ tmux status bar
- ✅ Kitty terminal
- ✅ btop
- ✅ lazygit
- ✅ bat (via BAT_THEME)
- ✅ Neovim (set in LazyVim config)

---

## 📝 Manual Steps

Some things cannot be automated:

1. **Age identity key**: Import `~/.config/chezmoi/key.txt` from backup
2. **Firefox extensions**: Use Firefox Sync (sign in with your Firefox account)
3. **VS Code**: Sign in to Settings Sync (GitHub account)
4. **GNOME extensions** (native only): Install via Extension Manager:
   - Bluetooth Battery Meter
   - System Monitor
   - Grand Theft Focus
   - Caffeine
   - Burn My Windows
   - Coverflow Alt-Tab
   - GNOME UI Tune
   - Impatience
   - Primary Input on Lock Screen
   - Places Menu

---

## 🧪 CI/CD

GitHub Actions runs on every push/PR to `main`:

- **Lint**: shellcheck, shfmt, hadolint, yamllint, template validation
- **Test Matrix**: Bootstrap test in Docker for:
  - `ubuntu-24.04-native`
  - `ubuntu-24.04-wsl` (simulated)
  - (Extensible for Arch, Fedora, etc.)
- **Idempotency**: Verifies bootstrap can run twice without errors

---

## 📄 License

Personal dotfiles. Use at your own risk.
