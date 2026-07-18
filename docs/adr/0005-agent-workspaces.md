# ADR 0005: Parameterized Agent Workspaces

Status: Superseded by [ADR 0006](0006-backend-aware-agent-workspaces.md)

## Decision

This record captures the original tmuxp-only decision. ADR 0006 replaces the
backend choice while retaining the registry, reproducibility, and supervised
single-working-directory constraints below.

Use one tmuxp YAML template rendered for the current project and run a pinned
tmuxp version through `uvx`. Give each configured agent a window and preserve a
usable shell when an optional agent is absent.

## Consequences

Workspaces are repeatable without global tmuxp drift. Authentication and agent
session directories remain outside repository ownership.

This ADR does not prescribe Git branches, worktrees, concurrent writers, or
automated commit/merge behavior. The default operating model is one editing
agent per working directory, with other windows used for review, diagnosis,
research, and test observation. Any future multi-writer coordination model
requires a separate ADR and evidence that it improves this personal workflow.
