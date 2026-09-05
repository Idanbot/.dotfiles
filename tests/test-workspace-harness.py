#!/usr/bin/env python3
"""Mutate the real workspace suite, never the installed workspace commands."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


root = Path(sys.argv[1]).resolve()
source = (root / "tests/e2e/test-agent-workspace.sh").read_text()
mutations = {
    "first": ('  grep -Fq \'[PASS] codex\' <<<"$output"', '  false # first assertion'),
    "middle": ('  grep -Fq \'[PASS] claude\' <<<"$output"', '  false # middle assertion'),
    "last": ('  dot-workspace "$WORKSPACE_DIR" --backend tmux --check >/dev/null', '  false # last assertion'),
    "missing-agents": (
        '  local agent count\n',
        '  local agent count\n  awk -F "\\t" \'BEGIN {OFS="\\t"} $1 != "omp" {$1="codex"} {print}\' "$AGENT_RUN_LOG" >"$TMP_ROOT/broken"\n  cp "$TMP_ROOT/broken" "$AGENT_RUN_LOG"\n',
    ),
    "wrong-directory": (
        '  local agent count\n',
        '  local agent count\n  sed -i "1s|$WORKSPACE_DIR|/wrong-directory|" "$AGENT_RUN_LOG"\n',
    ),
    "mcp-count": ('  [[ "$enabled_count" -eq 10 ]]', '  enabled_count=9\n  [[ "$enabled_count" -eq 10 ]]'),
    "negative-assertion": (
        '  if grep -Eq \'[[:space:]]enabled$\' <<<"$status_output"; then return 1; fi',
        '  if grep -Eq \'[[:space:]]enabled$\' <<<" enabled"; then return 1; fi',
    ),
    "backend-command": (
        'yaml="${!#}"',
        'exit 37 # fail the actual tmuxp backend command\nyaml="${!#}"',
    ),
}

with tempfile.TemporaryDirectory(prefix="workspace-harness-") as temp:
    work = Path(temp)
    for name, mutation in [("baseline", None), *mutations.items()]:
        script = work / f"{name}.sh"
        content = source
        if mutation:
            old, new = mutation
            assert old in content, (name, "mutation anchor missing")
            content = content.replace(old, new, 1)
        script.write_text(content)
        artifacts = work / name
        result = subprocess.run(
            ["bash", str(script), str(root)],
            env={**os.environ, "DOTFILES_E2E_ARTIFACT_DIR": str(artifacts)},
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120,
        )
        summary = json.loads((artifacts / "summary.json").read_text())
        events = [json.loads(line) for line in (artifacts / "workspace-events.jsonl").read_text().splitlines()]
        failures = [event for event in events if event["state"] == "fail"]
        try:
            assert summary["cases"]["total"] == 6
            assert summary["cases"]["failed"] == len(failures)
            assert summary["cases"]["passed"] + len(failures) == 6
            if mutation:
                assert result.returncode != 0, "broken fixture passed"
                assert summary["result"] == "fail" and failures
                assert "[FAIL]" in result.stdout
                assert "case=" in result.stdout and "line=" in result.stdout
                expected = (
                    "agent CLI preflight" if name in ("first", "middle", "last") else
                    "working-directory propagation" if name in ("missing-agents", "wrong-directory") else
                    "tmuxp backend execution" if name == "backend-command" else
                    "MCP enable and disable"
                )
                assert expected in [event["case"] for event in failures]
                if name in ("first", "middle", "last"):
                    assert len(failures) == 1
            else:
                assert result.returncode == 0 and not failures
                assert summary["result"] == "pass"
        except AssertionError:
            print(result.stdout)
            print(summary)
            raise
        print(f"[PASS] workspace harness: {name}", flush=True)
