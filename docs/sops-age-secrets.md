# SOPS & Age Secrets Management Guide

This guide explains how to manage encrypted secrets, host overlays, and environment variables in your dotfiles using **SOPS** (Secrets OCP Service) and **age** (modern encryption tool).

---

## 1. Overview

- **`age`**: A simple, modern, and secure file encryption tool using X25519 ECC keys.
- **`sops`**: An editor of encrypted files that supports YAML, JSON, ENV, INI, and binary formats, encrypting values while leaving keys unencrypted for git diff readability.

Using SOPS with `age` allows you to safely check encrypted secret overlays into public dotfile repositories without exposing sensitive API tokens, private SSH keys, or server credentials.

---

## 2. Generating an Age Keypair

Generate an `age` keypair on your machine:

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

This generates:
- **Public key**: `age1...` (Safe to share and commit into `.sops.yaml`)
- **Private key**: Stored securely in `~/.config/sops/age/keys.txt` (Must **never** be committed)

Set the environment variable in your shell (`.zshrc`):

```bash
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
```

---

## 3. Configuring `.sops.yaml`

Create a `.sops.yaml` file in the root of your repository to declare encryption rules:

```yaml
creation_rules:
  - path_regex: .*\.enc\.(yaml|env|json)$
    age: "age1ql3z7hjy54pw302mvse53kwvrjv532kr6arac0kjap9av72xv5dqwh7f72"
```

Replace the `age` public key with your actual generated public key.

---

## 4. Encrypting & Editing Secret Overlays

### Creating an Encrypted File
To create or edit an encrypted file with SOPS:

```bash
sops secrets.enc.env
```

Your default `$EDITOR` (e.g. `nvim` or `vim`) will open. Add your secrets:

```env
DATABASE_URL=postgres://user:password@localhost:5432/mydb
CLOUDFLARE_API_TOKEN=secret_token_here
```

When you save and exit, SOPS automatically encrypts the values using `age`.

### Decrypting / Viewing Secrets
To view decrypted content on stdout:

```bash
sops -d secrets.enc.env
```

To export secrets into your local shell session safely:

```bash
eval $(sops -d --output-type dotenv secrets.enc.env)
```

---

## 5. Integrating with Chezmoi

You can decrypt secrets dynamically inside `chezmoi` templates (`.tmpl` files):

```gotemplate
{{ if stat (joinPath .chezmoi.homeDir ".config/sops/age/keys.txt") -}}
# Decrypted via SOPS
export API_KEY="{{ output "sops" "-d" "--extract" "[\"API_KEY\"]" (joinPath .chezmoi.sourceDir "secrets.enc.yaml") | trim }}"
{{- end }}
```

Alternatively, keep machine-specific encrypted overlays in `.config/dotfiles/local.zsh` ignored by `.chezmoiignore`.
