# ADR 0003: Verified Tool Ownership

Status: Accepted

## Decision

Every direct download must have an integrity source, and every managed install
must record an owner and target. Distro packages rely on signed repositories;
release assets use upstream checksums or reviewed hashes.

## Consequences

Version changes are reviewable and safe removal is possible through the ledger.
Some upstream updates require manual hash review rather than blind automation.
