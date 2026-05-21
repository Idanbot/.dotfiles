# Phase 4: Chezmoi Dotfiles and Safe Migration

## Goal

Build curated, public-safe chezmoi templates based on current workflows without copying secrets from live dotfiles.

## Target Outcome

Chezmoi manages shell, tmux, git, LazyVim, mise, starship, and SSH config templates. Existing local configuration is used as source material only after secret scanning is in place.

## Required Files

- `chezmoi/dot_zshrc.tmpl`
- `chezmoi/dot_zshrc.local.example`
- `chezmoi/dot_tmux.conf`
- `chezmoi/dot_gitconfig.tmpl`
- `chezmoi/dot_gitconfig-personal.tmpl`
- `chezmoi/dot_gitconfig-work.tmpl`
- `chezmoi/dot_config/nvim/`
- `chezmoi/dot_config/starship.toml`
- `chezmoi/dot_config/mise/config.toml`
- `chezmoi/private_dot_ssh/config.tmpl`
- `scripts/audit-dotfile-import.sh`

## Migration Policy

Use curated templates, not wholesale copies.

Before reading or importing current live files:

- `gitleaks` must exist and pass.
- A local import audit script must exist.
- Files must be scanned before copying into `chezmoi/`.
- Secrets must be moved to local-only or Bitwarden-backed paths.
- Useful emails, aliases, and hostnames must be reviewed before commit.

Current files to evaluate after the security gate:

- `~/.zshrc`
- `~/.zsh/functions/`
- `~/.tmux.conf`
- current Neovim/LazyVim config
- current shell aliases
- current CLI tooling configs
- current Git config patterns

## Secret Handling Rules

- Inline exports like `CF_TOKEN=...` must not be committed.
- `.zshrc` may source `~/.zshrc.local` if present.
- `~/.zshrc.local` is never managed by chezmoi and is never committed.
- Cloudflare token access should move to Bitwarden-backed explicit commands.
- Basic shell startup must not require Bitwarden.

## Oh My Zsh Requirements

- Install or configure Oh My Zsh as the default framework.
- Keep plugin choices curated and documented.
- Avoid plugins that require secrets during shell startup.
- Ensure shell startup works in CI without interactive prompts.
- Use starship if compatible with the selected Oh My Zsh setup.

## LazyVim Requirements

- Use LazyVim as the v1 Neovim distribution.
- Curate plugins before committing.
- Include Terraform, YAML, Kubernetes, Go, Python, TypeScript, JavaScript, Markdown, JSON, and shell support where appropriate.
- Avoid committing machine-local plugin state.
- CI should run `nvim --headless '+q'`.
- Lazy plugin sync may be tested separately if it proves stable.

## Detailed Tasks

- Create base chezmoi source directory.
- Add `.zshrc` template that sources `~/.zshrc.local` if present.
- Add `dot_zshrc.local.example` with placeholder examples and no secrets.
- Add shell functions directory using chezmoi naming conventions.
- Add tmux config.
- Add Git config split with `includeIf`.
- Include Git name/email if approved for public repo.
- Add comments explaining how to override Git identity locally if needed.
- Add SSH config template without private keys.
- Add starship config.
- Add mise config.
- Add LazyVim config.
- Scan all imported material with `gitleaks`.
- Review aliases before commit for private hostnames or client references.

## Acceptance Criteria

- `chezmoi apply` works in basic mode.
- `chezmoi diff --exit-code` passes after apply.
- `zsh -i -c 'echo shell-ok'` works without secrets.
- `tmux -V` works.
- `nvim --headless '+q'` works.
- No token, key, or password appears in tracked files.

## Tests

- Run `gitleaks detect --source . --redact`.
- Run `chezmoi apply --source ./chezmoi`.
- Run `chezmoi diff --source ./chezmoi --exit-code`.
- Run `zsh -i -c 'echo shell-ok'`.
- Run `nvim --headless '+q'`.

## Risks

- Existing config may contain secrets or private aliases. Import must be staged and reviewed.
- Oh My Zsh plugins can slow startup or create hidden dependencies. Measure shell startup if it becomes noticeable.

