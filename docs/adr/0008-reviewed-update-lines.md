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

Latest stable is the default grouped proposal for versioned packages. Every
manifest entry is accounted for in the standing advisory, including packages
that cannot be advanced by changing a pin. Distro and signed vendor APT
packages follow their repositories; some also show upstream freshness for
reference. Mutable vendor installers propose checksum changes, not runtime
versions. Font family selection is separate from the tracked font release.

The installer still uses an explicit kubectl pin. Grouped proposals advance
only its current minor line to avoid unreviewed
[client/server skew](https://kubernetes.io/releases/version-skew-policy/#kubectl). GitHub CLI,
AWS CLI, Helm, and Terraform retain their current majors in grouped proposals
and at install time. New lines appear in the advisory and require explicit
review. GCloud uses a vendor SDK train and cloudflared calendar releases;
SDK increments and year rollovers do not imply backwards compatibility.
All installation paths still enforce integrity and ownership.
Optional freshness lookup failures warn if the installed version already meets
the baseline. Required capability, checksum, signature, and APT authentication
failures remain blocking; there is no unverified or silently downgraded fallback.

An explicit `--reviewed-baseline` run bypasses latest-version discovery and selects
exact repository pins, reporting freshness unknown. It does not retry a failed
rolling resolution silently. Tools without an exact numeric repository baseline
(including distro-valued cloud SDK pins) cannot use this mode; resolve them normally
or establish a reviewed exact pin first. Artifact availability, checksums, signatures,
APT authentication and preflight requirements remain blocking. Resume preserves
the chosen discovery mode and original resolved targets.

CI advisory discovery runs in separate scheduled/manual maintenance workflows,
not on every acceptance run. Advisory failures cannot skip release smoke or make
unverified payloads acceptable. Failed weekly audits mark the standing advisory
issue incomplete, with a UTC timestamp and source revision; the grouped PR stays unchanged.

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
