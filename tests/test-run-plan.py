#!/usr/bin/env python3
"""Regression coverage for immutable resume inputs, without installing tools."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    source = base / "source"
    run = base / "run"
    source.mkdir()
    run.mkdir()
    manifest = source / "packages.yaml"
    manifest.write_text("version: 1\n")
    command = [sys.executable, str(root / "scripts/run-plan.py"), "prepare",
               "--source", str(source), "--run-dir", str(run),
               "--sections", "languages", "--profile", "custom",
               "--conflict-policy", "skip", "--doctor", "false"]
    subprocess.run(command, check=True)
    plan = run / "plan.json"
    original = plan.read_bytes()
    assert plan.stat().st_mode & 0o777 == 0o600
    subprocess.run(command + ["--resume"], check=True)
    assert plan.read_bytes() == original
    options = subprocess.check_output([
        sys.executable, str(root / "scripts/run-plan.py"), "options",
        "--run-dir", str(run)], text=True)
    assert "conflict_policy\tskip" in options and "doctor\tfalse" in options
    for option, value in [("--sections", "ai"), ("--profile", "full"),
                          ("--conflict-policy", "replace"), ("--doctor", "true")]:
        changed = command.copy()
        changed[changed.index(option) + 1] = value
        result = subprocess.run(changed + ["--resume"], capture_output=True, text=True)
        assert result.returncode and "Resume inputs changed" in result.stderr
        assert plan.read_bytes() == original
    manifest.write_text("version: 2\n")
    result = subprocess.run(command + ["--resume"], capture_output=True, text=True)
    assert result.returncode and "source_sha256" in result.stderr
    assert plan.read_bytes() == original
    assert json.loads(original)["schema"] == 1
    plan.unlink()
    result = subprocess.run(command + ["--resume"], capture_output=True, text=True)
    assert result.returncode and "Legacy run" in result.stderr
print("PASS: resume validates source, options, private plan, and legacy refusal")
