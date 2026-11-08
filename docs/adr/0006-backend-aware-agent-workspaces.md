# ADR 0006: Tmux Agent Workspaces

Status: accepted; updated 2026-11-08.

## Decision

Use tmux as the single workspace implementation. Render the common agent registry
and optional presets into tmuxp YAML and run the pinned tmuxp through uvx.
Both legacy `--backend auto` and `--backend tmux` select tmux.

Names include a canonical-directory hash and optional preset suffix. Explicit
name collisions with another directory fail. Existing same-directory sessions
are attached/focused without replacing user panes or restarting agents.

`--print` renders YAML; `--plan` inspects desired/current window labels without
mutation. Unavailable inspection is unknown, not evidence of absent sessions.
The standard prefix is Ctrl+S. Agent authentication and state remain manual.

## Verification

Docker fixtures exercise registry paths, presets, working directories with spaces,
name collisions, reuse, missing/crashing agents and non-mutating drift previews.
No user session is modified by tests.
