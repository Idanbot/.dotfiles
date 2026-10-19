# Reviewed Update Lines and Existing-Machine Upgrades

Status: accepted, 2026-10-19.

## Decision

Prefer predictable, mostly safe updates over forcing every existing installation
to match a freshly installed machine. Preserve external, newer, modified, and
legacy-unverifiable binaries. A ledger entry alone is not proof of ownership.
Preflight uses the same digest verifier as installation and explains the skip.

Languages install repository-reviewed minimums. Grouped proposals follow
`scripts/update-policy.json`: Node/TypeScript stay within a major, Python/Go
within a minor line, Java within a feature release, Rust/Cargo track stable,
and standalone package managers may cross majors. npm candidates must support
the proposed Node runtime and installs enforce the engine requirement. Explicit
version acceptance remains available to change a release line.

The existing cloud-specific rolling policy and explicit kubectl pin remain.
Optional freshness lookup failures warn if the installed version already meets
the baseline. Required capability, checksum, signature, and APT authentication
failures remain blocking; there is no unverified or silently downgraded fallback.

Before applying configuration, validate that the exact Python pin is downloadable
with active uv or a temporary, checksum-verified repository-pinned uv. Do not
replace an external uv just to update its embedded Python catalog.

Cache payloads and immutable verification material, not successful trust results.
Rehash payloads and reverify AWS signatures on every use. Store private local
digests to detect cache corruption; these do not replace vendor authenticity.
Repair scoped HashiCorp keys before the first APT refresh when helpers are
available. Stop on stale/failed APT indexes instead of reporting success.

## Maintenance and Validation

Weekly CI edits one standing latest-stable advisory issue, including suggestions
outside automatic release lines. Monthly automation refreshes the existing
grouped-upgrade branch and PR, validates checksums, and dispatches the heavy
canary. No per-tool issues, branches, PRs, or weekly comment accumulation.

CI covers stale uv, missing Python builds, cache corruption/reuse, signature
reverification, legacy/modified ownership, version probe failures, WSL routing,
APT repair ordering, and singleton advisory publication. Local installed tools
and credentials are not used as mutable test fixtures.
