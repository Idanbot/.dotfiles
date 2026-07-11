# Security Model

## Current Decision

The public repository and unattended bootstrap are secret-free. SOPS is a
managed utility, but SOPS/age encryption is not configured and no age identity
is generated, requested, imported, or logged.

This trades automatic credential restoration for a smaller and auditable
bootstrap trust boundary.

## Sensitive Material Kept Out

- SSH private keys, certificates, known private host aliases, and agent state.
- GPG private keys and trust databases.
- Git credential stores, GitHub tokens, and GCM login state.
- AWS credentials, Google Cloud/Azure profiles, kubeconfigs, Terraform backend
  credentials, and Cloudflare tokens.
- `.env` files, API keys, password stores, browser data, and keyring content.
- Authentication/session directories for every AI CLI.
- SOPS recovery data and age private identities.

These are restored or authenticated manually after a bootstrap.

## Local Extension Boundary

Machine-only shell, tmux, Git, SSH, and profile files are ignored by chezmoi.
The doctor checks existing local overlays for private modes. Installer logs are
mode `0600`, ANSI-free on disk, and redact common `token=`, `password=`,
`secret=`, and `api_key=` assignments.

Redaction is defense in depth, not permission to pass secrets through the
installer environment or command line.

## Supply Chain Controls

- Distro packages use signed Ubuntu/vendor repositories.
- Added APT keys are checked against pinned fingerprints.
- Release archives use upstream checksum manifests or reviewed SHA256 values.
- Chezmoi externals use immutable refs and pinned SHA256 values.
- GitHub Actions use full commit SHAs.
- Gitleaks scans full history without broad path exclusions.
- Trivy scans vulnerabilities, secrets, and configuration.
- Actionlint, Zizmor, Hadolint, and dependency review gate E2E execution.

Checksums do not replace signatures, but they prevent accidental or unreviewed
asset drift and make version changes explicit.

## Future Encrypted Recovery

If automatic secret recovery is added later, retain the public bootstrap as the
first phase and add a separate opt-in source. Required design constraints:

1. No private age key in Git, CI, shell history, bootstrap logs, or artifacts.
2. One documented offline recovery path and key-rotation procedure.
3. Explicit file allowlist; never encrypt whole application state directories.
4. Decrypt only after public bootstrap acceptance succeeds.
5. Validate destination modes before and after restore.
6. CI uses synthetic encrypted fixtures, never production recipients or data.
7. Agent authentication caches remain excluded even if other credentials are
   later automated.

Candidate secret files should be reviewed individually. Likely examples are a
minimal kubeconfig, selected cloud credential files, or private SSH keys;
machine-generated caches, histories, sockets, and session databases should not
be synchronized.

## Incident Response

If a secret is committed, deleting the working-tree file is insufficient:

1. Revoke or rotate the credential immediately.
2. Identify affected history and CI artifacts.
3. Remove the data from Git history when warranted.
4. Invalidate caches/artifacts and notify affected systems.
5. Add a narrow regression rule or fixture without broad scan exclusions.
