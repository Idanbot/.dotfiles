# ADR 0001: Secret-Free Public Bootstrap

Status: Accepted

## Decision

Keep the repository and unattended bootstrap free of credentials, encrypted
secret payloads, and age identities. Install SOPS as a utility only. Restore
credentials and authenticate tools manually after public bootstrap acceptance.

## Consequences

Fresh-machine setup has a manual credential phase, but public CI and logs cannot
depend on production secret material. A future encrypted recovery source must
be separate and opt-in.
