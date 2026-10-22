# Opt-In Local Review

These tools help you inspect an existing machine before deciding what to share.
They do not run automatically during installation, CI, or agent sessions. CI
tests them only against synthetic homes, versions, configurations, and advisories.
No private machine report is attached to Actions, an issue, or an agent.

Before installing the updated `dot` command, the same interface is available as:

```bash
/usr/bin/python3 scripts/local-review.py check --json
```

## Offline Check

`dot check-local [--json] [--output FILE]` performs syntax-only shell checks,
private-state/MCP permission checks, and catalog/selection validation. It never
sources your shell config, runs cloud commands, reads SSH keys or credential
stores, changes configuration, or makes network requests. Temporary parser homes
are disposable and parser stdout/stderr are discarded.

Output contains only fixed check IDs and `ok`, `attention`, or `unavailable`.
It contains no raw diagnostic output, file contents, paths, username, hostname,
versions, accounts, or project names. An attention result exits 1; unavailable
checks are not a claim of success. You decide whether to share any output.

| Check ID | What To Review Locally |
| --- | --- |
| `shell.zsh.syntax`, `shell.bash.syntax`, `shell.profile.syntax` | Shell syntax; the command never executes the file |
| `state.permissions` | Dotfiles state must not be accessible to other users |
| `mcp.*.permissions` | Review symlinked or group/world-accessible MCP configurations |
| `catalog.integrity` | Repair malformed catalog/selection data with the existing lifecycle commands |

This is a narrow diagnostic, not an existing-machine installation simulation or
a guarantee that configuration contains no secrets. Do not share raw configs or
startup traces just because the code-only report is safe to review.

## Software Receipts

```bash
dot receipt create --output /tmp/receipt-a.json
dot receipt compare /tmp/receipt-a.json /tmp/receipt-b.json
```

A receipt has a strict schema: supported platform enums, public manifest hash,
source commit when available, known section/tool IDs, normalized numeric versions,
probe state, and a management classification. It never includes user paths,
timestamps, usernames, hostnames, Git identity/remotes, credentials, config text,
raw tool output, or cloud contexts. Compare validates both inputs before printing
anything; unknown fields and malformed values are rejected without echoing them.

Receipts do reveal your software inventory and selected capabilities. They are
not anonymous telemetry and are never sent anywhere automatically. Share only
after review. Versions come from a current existing catalog snapshot; no binary
is executed to create a receipt. Use `dot tools refresh` separately when you
choose to run version probes. Missing, changed, or unsupported observations stay
unknown instead of using the repository pin as an installed version.

`recorded-unverified` means a matching ledger path exists, not that its bytes
were reverified. Receipts do not certify ownership or authorize replacement.

## Typed Capture

```bash
dot capture --list
dot capture zsh --output /tmp/zsh-settings.patch
dot capture tmux --output /tmp/tmux-settings.patch
dot capture starship --output /tmp/prompt-settings.patch
```

Only allowlisted literals are supported: Zsh history limits; tmux mouse/history/
status interval; and selected numeric/boolean Starship preferences. Arbitrary
aliases, functions, environment values, account/context names, URLs, paths,
comments, SSH/Git settings, and credential files are not exported. Computed
values, symlinked inputs, ambiguous templates, and unsupported source forms fail
closed. This deliberately does not capture every local customization.

The private patch targets the repository template, contains zero neighboring
context lines, and never modifies source or destination. Review it yourself
before applying with `git apply --unidiff-zero /tmp/zsh-settings.patch`. It is not
a general `chezmoi add` replacement or a secret scanner.

## Installed-Version CVE Review

`dot audit --installed` uses the same receipt model and defaults to offline mode.
Without matching local advisory data, results are unknown, not clean. Supply
`--receipt FILE` to audit an exported receipt without probing the machine.

`--online` explicitly permits OSV requests containing public package coordinates
and observed versions only. No paths, usernames, host identity, configuration,
credentials, or cloud contexts are transmitted. `--cache-output FILE` saves a
sanitized advisory snapshot for later offline `--advisories FILE` use; vendor
summaries, URLs, and arbitrary response text are not retained.
Only recognized advisory-ID formats are exported; unsupported response formats
fail closed without echoing their contents.

Results distinguish missing, unobserved, unsupported, unknown, known advisories,
and no known advisories in the dated dataset. Repository pins are never
substituted for observed versions. Unknown coverage and stale snapshots cannot
establish safety. CVSS vectors are scored when the pinned audit dependencies in
`requirements-audit.txt` are available; otherwise vector-only findings remain
unscored. The report is advisory and never changes pins or installed software.

All explicit output files use `0600`, refuse existing/symlinked targets and
redirected parent paths, and remain local. There is no upload command.
