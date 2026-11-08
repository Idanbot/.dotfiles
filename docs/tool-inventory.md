# Tool Inventory

Generated from `packages.yaml` and `packages.meta.yaml`. Update manifests first, then regenerate with:

```bash
./scripts/generate-tool-inventory.sh
```

| Section | Tool | Version | Source | Owner | Integrity |
|---------|------|---------|--------|-------|-----------|
| bootstrap | chezmoi | 2.74.0 | apt_or_github | bootstrap | upstream-checksum |
| core | bubblewrap | distro | apt | apt | apt-signature |
| core | fzf | 0.75.0 | external | chezmoi-external | pinned-sha256 |
| core | fd | 10.4.2 | apt | apt | apt-signature |
| core | ripgrep | 15.1.0 | apt | apt | apt-signature |
| core | bat | 0.26.1 | apt | apt | apt-signature |
| core | eza | 0.23.5 | github | dotfiles-binary | pinned-sha256 |
| core | lazygit | 0.66.3 | github | dotfiles-binary | upstream-checksum |
| core | btop | 1.4.7 | apt | apt | apt-signature |
| core | starship | 1.27.0 | github | dotfiles-binary | upstream-checksum |
| core | github_cli | 2.103.3 | github | dotfiles-binary | pinned-sha256 |
| core | jq | distro | apt | apt | apt-signature |
| core | gojq | distro | apt | apt | apt-signature |
| core | yq | distro | apt | apt | apt-signature |
| core | pigz | distro | apt | apt | apt-signature |
| core | zstd | distro | apt | apt | apt-signature |
| core | htop | distro | apt | apt | apt-signature |
| core | zoxide | distro | apt | apt | apt-signature |
| core | direnv | distro | apt | apt | apt-signature |
| core | git-delta | distro | apt | apt | apt-signature |
| core | hyperfine | distro | apt | apt | apt-signature |
| core | duf | distro | apt | apt | apt-signature |
| core | sops | 3.13.3 | github | dotfiles-binary | upstream-checksum |
| core | lazydocker | 0.25.2 | github | dotfiles-binary | upstream-checksum |
| core | tealdeer | 1.9.1 | github | dotfiles-binary | upstream-checksum |
| core | curlie | 1.8.2 | github | dotfiles-binary | upstream-checksum |
| core | trippy | 0.13.0 | github | dotfiles-binary | pinned-sha256 |
| core | ast_grep | 0.51.1 | github | dotfiles-binary | pinned-sha256 |
| core | gitleaks | 8.30.1 | github | dotfiles-binary | pinned-sha256 |
| languages | go | 1.27.3 | direct | dotfiles-runtime | upstream-checksum |
| languages | rust | 1.99.1 | rustup | rustup | upstream-checksum |
| languages | cargo | 1.99.1 | rustup | rustup | rustup |
| languages | node | 26.13.0 | node-dist | dotfiles-runtime | upstream-checksum |
| languages | npm | 12.2.2 | npm | node-runtime | npm-registry |
| languages | typescript | 7.0.2 | npm | npm | npm-registry |
| languages | python | 3.14.10 | uv | uv | uv-managed |
| languages | java | 25.0.5+8 | github | dotfiles-runtime | pinned-sha256 |
| languages | uv | 0.13.7 | github | dotfiles-binary | upstream-checksum |
| history | atuin | 18.24.5 | github | dotfiles-binary | upstream-checksum |
| editor | neovim | 0.12.6 | github | dotfiles-runtime | pinned-sha256 |
| database | usql | 0.21.6 | github | dotfiles-binary | pinned-sha256 |
| database | iredis | 1.16.1 | pypi | uv | pypi |
| database | pgloader | distro | apt | apt | apt-signature |
| cloud | docker | distro | apt_repo | apt | apt-signature |
| cloud | kubectl | 1.37.2 | direct | dotfiles-binary | upstream-checksum |
| cloud | helm | 4.3.1 | github | dotfiles-binary | upstream-checksum |
| cloud | terraform | 1.17.1 | direct | dotfiles-binary | upstream-checksum |
| cloud | ansible | distro | apt | apt | apt-signature |
| cloud | k9s | 0.51.0 | github | dotfiles-binary | upstream-checksum |
| cloud | aws_cli | 2.39.6 | direct | vendor-installer | pinned-sha256 |
| cloud | gcloud | distro | apt_repo | apt | apt-signature |
| cloud | azure_cli | distro | apt_repo | apt | apt-signature |
| cloud | cloudflared | 2026.10.7 | github | vendor-installer | pinned-sha256 |
| cloud | s5cmd | 2.3.0 | github | dotfiles-binary | upstream-checksum |
| cloud | kcat | distro | apt | apt | apt-signature |
| cloud | stern | 1.35.0 | github | dotfiles-binary | upstream-checksum |
| cloud | helmfile | 1.8.3 | github | dotfiles-binary | upstream-checksum |
| cloud | kubectx | 0.11.0 | github | dotfiles-binary | upstream-checksum |
| cloud | kubens | 0.11.0 | github | dotfiles-binary | upstream-checksum |
| cloud | kubecolor | 0.8.0 | github | dotfiles-binary | upstream-checksum |
| cloud | radar | 1.20.1 | github | dotfiles-binary | pinned-sha256 |
| terminal | kitty | 0.49.2 | github | dotfiles-binary | pinned-sha256 |
| terminal | tmux | distro | apt | apt | apt-signature |
| terminal | tmuxp | 1.76.0 | uvx | ephemeral | pypi |
| system | git_credential_manager | 3.0.2 | github | dpkg | pinned-sha256 |
| fonts | nerd_font | FiraMono | github | dotfiles-assets | upstream-checksum |
| fonts | nerd_font_version | 3.5.1 | github | dotfiles-assets | upstream-checksum |
| ai_tools | claude_cli | 2.1.319 | npm | npm | npm-registry |
| ai_tools | codex_cli | standalone | install_script | vendor-installer | pinned-sha256 |
| ai_tools | antigravity_cli | standalone | install_script | vendor-installer | pinned-sha256 |
| ai_tools | opencode | 1.19.5 | npm | npm | npm-registry |
| ai_tools | omp | 18.18.1 | github | dotfiles-binary | pinned-sha256 |
| ai_tools | bun | 1.4.4 | github | dotfiles-binary | pinned-sha256 |
| ai_tools | serena | 1.7.0 | uv | uv | pypi |
| ai_tools | context_mode | 1.0.169 | npm | npm | npm-registry |
| ai_tools | graphify | 0.9.104 | pypi | uv | pypi |
| ai_tools | rtk | 0.51.0 | github | dotfiles-binary | pinned-sha256 |
| ai_tools | ponytail | 5.3.3 | github | agent-skill | pinned-sha256 |
| ai_tools | pix_optimizer | 1.3.5 | npm | omp-plugin | npm-registry |
| media | yt_dlp | 2026.10.26 | uv | uv | pypi |
| media | rmpc | 0.11.0 | github | dotfiles-binary | pinned-sha256 |
| media | cava | distro | apt | apt | apt-signature |
