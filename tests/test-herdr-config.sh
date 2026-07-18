#!/usr/bin/env bash
# Validate safety, UX, and keybinding contracts in the managed Herdr config.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG="$DOTFILES_DIR/dot_config/herdr/config.toml"

python3 - "$CONFIG" <<'PY'
from __future__ import annotations

import sys
import tomllib
from pathlib import Path

path = Path(sys.argv[1])
config = tomllib.loads(path.read_text(encoding="utf-8"))

assert config["onboarding"] is False
assert config["theme"]["name"] == "catppuccin"
assert config["terminal"]["new_cwd"] == "follow"
assert config["update"]["channel"] == "stable"

keys = config["keys"]
assert keys["prefix"] == "ctrl+s"
assert keys["focus_pane_left"] == "prefix+h"
assert keys["focus_pane_down"] == "prefix+j"
assert keys["focus_pane_up"] == "prefix+k"
assert keys["focus_pane_right"] == "prefix+l"
assert keys["switch_tab"] == "prefix+1..9"
assert keys["focus_agent"] == "prefix+alt+1..9"
assert keys["navigate_workspace_up"] == "shift+k"
assert keys["navigate_workspace_down"] == "shift+j"
assert keys["new_worktree"] == ""
assert keys["open_worktree"] == ""
assert keys["remove_worktree"] == ""

bindings = [value for value in keys.values() if isinstance(value, str) and value]
assert len(bindings) == len(set(bindings)), "duplicate Herdr keybinding"

commands = keys["command"]
command_keys = [entry["key"] for entry in commands]
assert len(command_keys) == len(set(command_keys))
assert {"prefix+alt+g", "prefix+alt+d", "prefix+alt+k", "prefix+alt+h", "prefix+alt+o"} <= set(command_keys)
assert "prefix+ctrl+s" not in command_keys

ui = config["ui"]
assert ui["agent_panel_sort"] == "priority"
assert ui["show_agent_labels_on_pane_borders"] is True
assert ui["toast"]["delivery"] == "herdr"
assert ui["sound"]["enabled"] is False
assert config["session"]["resume_agents_on_restore"] is True
assert config["remote"]["manage_ssh_config"] is True
assert config["experimental"]["allow_nested"] is False
assert config["experimental"]["pane_history"] is False
assert config["advanced"]["scrollback_limit_bytes"] >= 10_000_000
PY

if grep -Eqi '(token|password|secret|api[_-]?key)[[:space:]]*=' "$CONFIG"; then
  printf 'Herdr config must not contain credential assignments\n' >&2
  exit 1
fi

printf 'Herdr config test passed\n'
