#!/usr/bin/env bash
# Parse workflow semantics rather than depending on inline test filenames.
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
python3 "$ROOT/scripts/ci/contracts.py" "$ROOT"

# Parse both the hosted Bash and the quoted container payload without installing.
python3 - "$ROOT" <<'PY'
from pathlib import Path
import shlex
import subprocess
import sys

sys.path.insert(0, str(Path(sys.argv[1]) / "scripts/ci"))
import contracts

workflow = contracts.load(Path(sys.argv[1]) / ".github/workflows/arm64-smoke.yml")
for step in workflow["jobs"]["arm64-smoke"]["steps"]:
    if "run" not in step:
        continue
    subprocess.run(["bash", "-n"], input=step["run"], text=True, check=True)
    if step.get("id") == "smoke":
        argv = shlex.split(step["run"])
        subprocess.run(
            ["bash", "-n"], input=argv[argv.index("-c") + 1], text=True, check=True
        )
print("Periodic ARM64 host/container shell syntax passed (no live install)")
PY
