# ADR 0005: Parameterized Agent Workspaces

Status: Accepted

## Decision

Use one tmuxp YAML template rendered for the current project and run a pinned
tmuxp version through `uvx`. Give each configured agent a window and preserve a
usable shell when an optional agent is absent.

## Consequences

Workspaces are repeatable without global tmuxp drift. Authentication and agent
session directories remain outside repository ownership.
