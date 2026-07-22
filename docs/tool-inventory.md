# Tool Inventory

Generated from `packages.yaml` and `packages.meta.yaml`. Update manifests first, then regenerate with:

```bash
./scripts/generate-tool-inventory.sh
```

| Section | Tool | Version | Source | Owner | Integrity |
|---------|------|---------|--------|-------|-----------|
| bootstrap | chezmoi | 2.71.0 | apt_or_github | bootstrap | upstream-checksum |
| core | fzf | 0.74.0 | external | chezmoi-external | pinned-sha256 |
| core | fd | 10.4.2 | apt | apt | apt-signature |
| core | ripgrep | 15.1.0 | apt | apt | apt-signature |
| core | bat | 0.26.1 | apt | apt | apt-signature |
| core | eza | 0.23.4 | github | dotfiles-binary | pinned-sha256 |
| core | lazygit | 0.63.0 | github | dotfiles-binary | upstream-checksum |
| core | btop | 1.4.7 | apt | apt | apt-signature |
| core | starship | 1.26.0 | github | dotfiles-binary | upstream-checksum |
| core | jq | distro | apt | apt | apt-signature |
| core | yq | distro | apt | apt | apt-signature |
| core | htop | distro | apt | apt | apt-signature |
| core | zoxide | distro | apt | apt | apt-signature |
| core | direnv | distro | apt | apt | apt-signature |
| core | git-delta | distro | apt | apt | apt-signature |
| core | hyperfine | distro | apt | apt | apt-signature |
| core | duf | distro | apt | apt | apt-signature |
| core | sops | 3.13.2 | github | dotfiles-binary | upstream-checksum |
| core | lazydocker | 0.25.2 | github | dotfiles-binary | upstream-checksum |
| core | tealdeer | 1.8.1 | github | dotfiles-binary | upstream-checksum |
| core | curlie | 1.8.2 | github | dotfiles-binary | upstream-checksum |
| core | trippy | 0.12.2 | github | dotfiles-binary | upstream-checksum |
| languages | go | 1.26.5 | direct | dotfiles-runtime | upstream-checksum |
| languages | rust | stable | rustup | rustup | upstream-checksum |
| languages | cargo | stable | rustup | rustup | rustup |
| languages | node_lts | 24.18.0 | node-dist | dotfiles-runtime | upstream-checksum |
| languages | typescript | 7.0.2 | npm | npm | npm-registry |
| languages | python | 3.14.6 | uv | uv | uv-managed |
| languages | java | 21 | apt | apt | apt-signature |
| languages | uv | 0.11.28 | github | dotfiles-binary | upstream-checksum |
| history | atuin | 18.17.0 | github | dotfiles-binary | upstream-checksum |
| editor | neovim | 0.12.4 | github | dotfiles-runtime | pinned-sha256 |
| database | usql | 0.19.16 | github | dotfiles-binary | upstream-checksum |
| database | iredis | 1.15.0 | pypi | uv | pypi |
| cloud | docker | distro | apt_repo | apt | apt-signature |
| cloud | kubectl | 1.36.2 | direct | dotfiles-binary | upstream-checksum |
| cloud | helm | 4.2.3 | github | dotfiles-binary | upstream-checksum |
| cloud | terraform | 1.15.8 | direct | dotfiles-binary | upstream-checksum |
| cloud | ansible | distro | apt | apt | apt-signature |
| cloud | k9s | 0.51.0 | github | dotfiles-binary | upstream-checksum |
| cloud | aws_cli | 2.34.54 | direct | vendor-installer | pinned-sha256 |
| cloud | gcloud | distro | apt_repo | apt | apt-signature |
| cloud | azure_cli | distro | apt_repo | apt | apt-signature |
| cloud | cloudflared | distro | github | vendor-installer | upstream-checksum |
| cloud | stern | 1.32.0 | github | dotfiles-binary | upstream-checksum |
| terminal | kitty | distro | apt | apt | apt-signature |
| terminal | tmux | distro | apt | apt | apt-signature |
| terminal | tmuxp | 1.74.0 | uvx | ephemeral | pypi |
| terminal | herdr | 0.7.4 | github | dotfiles-binary | pinned-sha256 |
| system | git_credential_manager | 2.8.0 | github | dpkg | pinned-sha256 |
| fonts | nerd_font | FiraMono | github | dotfiles-assets | upstream-checksum |
| fonts | nerd_font_version | 3.4.0 | github | dotfiles-assets | upstream-checksum |
| ai_tools | claude_cli | 2.1.206 | npm | npm | npm-registry |
| ai_tools | codex_cli | standalone | install_script | vendor-installer | pinned-sha256 |
| ai_tools | gemini_cli | 0.50.0 | npm | npm | npm-registry |
| ai_tools | antigravity_cli | manual | manual | user | manual |
| ai_tools | opencode | 1.17.18 | npm | npm | npm-registry |
| ai_tools | omp | 16.4.0 | github | dotfiles-binary | pinned-sha256 |
| media | yt_dlp | 2026.07.04 | uv | uv | pypi |
| media | rmpc | 0.11.0 | github | dotfiles-binary | pinned-sha256 |
| media | cava | distro | apt | apt | apt-signature |
