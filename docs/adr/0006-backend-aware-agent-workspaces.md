# ADR 0006: Backend-Aware Agent Workspaces

Status: Accepted

Supersedes: [ADR 0005](0005-agent-workspaces.md)

## Context

The tmuxp-only launcher is reproducible, but running it from a Herdr pane hides
the actual agent processes behind tmux. Herdr then cannot provide agent state,
attention routing, or notifications. Giving both multiplexers the same prefix
also makes accidental nesting difficult to operate.

## Decision

`dot workspace` supports `auto`, `herdr`, and `tmux` backends. Auto routing:

1. Uses Herdr when already inside a Herdr-managed pane.
2. Uses tmuxp when already inside tmux.
3. Prefers Herdr on a bare terminal when the binary is available.
4. Falls back to tmuxp when Herdr is unavailable.

Cross-multiplexer launches fail unless `--allow-nested` is explicit. Both
multiplexers keep `Ctrl+S` as their normal prefix. Tmux's native `send-prefix`
supports Herdr beneath tmux. A generated tmuxp session explicitly nested under
Herdr uses `Ctrl+B` for that session only.

Both backends consume the managed copy of `agents.yaml`. Herdr creates one
project workspace with a terminal tab and one tab per agent. Tmuxp creates one
session with a terminal window and one window per agent. Existing named
workspaces/sessions are reused. Missing agent commands leave a login shell.

## Consequences

Herdr retains direct visibility of agents during normal Herdr operation. Tmuxp
remains available for terminal-first and recovery workflows without requiring
Herdr. Backend behavior is deterministic and testable through `--print`.

The launcher still does not create worktrees, coordinate concurrent writers,
commit, merge, push, authenticate agents, or manage agent session data.
