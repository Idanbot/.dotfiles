#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/repo/"{scripts,tests,dot_local/bin}
touch "$temporary/repo/scripts/example.sh" "$temporary/repo/dot_local/bin/executable_demo"
for tool in shellcheck shfmt yamllint; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "${0##*/}" "$*" >> "$CALLS"\n[ "${0##*/}" != "$FAIL_TOOL" ]\n' >"$temporary/bin/$tool"
  chmod +x "$temporary/bin/$tool"
done
export CALLS="$temporary/calls"
for tool in shellcheck shfmt yamllint; do
  if PATH="$temporary/bin:$PATH" FAIL_TOOL="$tool" bash "$ROOT/tests/test-lint.sh" "$temporary/repo" >"$temporary/output" 2>&1; then
    printf 'Ignored %s failure\n' "$tool" >&2
    exit 1
  fi
  grep -Fq "[FAIL] $tool" "$temporary/output"
done
PATH="$temporary/bin:$PATH" FAIL_TOOL=none bash "$ROOT/tests/test-lint.sh" "$temporary/repo"
grep -Fq 'dot_local/bin/executable_demo' "$CALLS"
grep -Fq 'SC1090,SC1091' "$CALLS"
! grep -Fq relaxed "$CALLS"

python3 - "$ROOT" "$temporary" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

root, temporary = map(Path, sys.argv[1:])
probe = temporary / "parallel"
binary = probe / "bin"
repo = probe / "repo"
binary.mkdir(parents=True)
for directory in ("scripts", "tests", "dot_local/bin"):
    (repo / directory).mkdir(parents=True)
files = [
    "scripts/one.sh", "scripts/two words.sh", "scripts/three\nlines.sh",
    "tests/four.sh", "dot_local/bin/executable_five",
]
for filename in files:
    (repo / filename).touch()
(repo / "dot_local/bin/executable_ignored.tmpl").touch()
(repo / "scripts/ignored.txt").touch()
for tool in ("shfmt", "yamllint"):
    path = binary / tool
    path.write_text("#!/bin/sh\nexit 0\n")
    path.chmod(0o755)
mock = binary / "shellcheck"
mock.write_text('''#!/usr/bin/python3
import fcntl, json, os, sys, time
from pathlib import Path
state_path = Path(os.environ["PROBE_STATE"])
def state(update=None):
    with state_path.with_suffix(".lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = json.loads(state_path.read_text()) if state_path.exists() else {
            "active": 0, "maximum": 0, "files": [], "batches": []}
        if update:
            update(data)
            state_path.write_text(json.dumps(data))
        return data
args = sys.argv[1:]
assert args[:5] == ["-x", "-S", "warning", "-e", "SC1090,SC1091"], args
def start(data):
    data["active"] += 1
    data["maximum"] = max(data["maximum"], data["active"])
    data["files"].extend(args[5:])
    data["batches"].append(args[5:])
state(start)
deadline = time.monotonic() + 2
while state()["maximum"] < 2 and time.monotonic() < deadline:
    time.sleep(0.01)
overlapped = state()["maximum"] >= 2
state(lambda data: data.update(active=data["active"] - 1))
if os.environ.get("FAIL_SHELL_FILE") in args[5:]:
    print("shellcheck fixture failure", flush=True)
    sys.exit(23)
sys.exit(0 if overlapped else 19)
''')
mock.chmod(0o755)
state = probe / "state.json"
completed = subprocess.run(
    ["bash", str(root / "tests/test-lint.sh"), str(repo)],
    env={**os.environ, "PATH": f"{binary}:{os.environ['PATH']}", "PROBE_STATE": str(state)},
    capture_output=True, text=True, timeout=10,
)
assert completed.returncode == 0, completed.stdout + completed.stderr
data = json.loads(state.read_text())
assert data["maximum"] == 2, data
assert data["active"] == 0, data
assert sorted(data["files"]) == sorted(files), data
for batch in data["batches"]:
    state.unlink()
    completed = subprocess.run(
        ["bash", str(root / "tests/test-lint.sh"), str(repo)],
        env={**os.environ, "PATH": f"{binary}:{os.environ['PATH']}",
             "PROBE_STATE": str(state), "FAIL_SHELL_FILE": batch[0]},
        capture_output=True, text=True, timeout=10,
    )
    assert completed.returncode != 0, completed.stdout + completed.stderr
    assert "shellcheck fixture failure" in completed.stdout, completed.stdout
    assert "[FAIL] shellcheck" in completed.stderr, completed.stderr
    assert "== shfmt ==" in completed.stdout, completed.stdout
    assert "== yamllint ==" in completed.stdout, completed.stdout
    failed_data = json.loads(state.read_text())
    assert failed_data["active"] == 0, failed_data
    assert sorted(failed_data["files"]) == sorted(files), failed_data

# An unlisted include supplies the array type; scalar expansion is only wrong
# when ShellCheck follows sources from the entrypoint.
real_repo = temporary / "source-context"
for directory in ("scripts", "tests", "dot_local/bin"):
    (real_repo / directory).mkdir(parents=True)
(real_repo / "scripts/shared.inc").write_text("SOURCED_LIST=(one two)\n")
entry = real_repo / "scripts/entry.sh"
clean = ('#!/usr/bin/env bash\nsource scripts/shared.inc\n'
         'printf "%s\\n" "${SOURCED_LIST[@]}"\n')
entry.write_text(clean)
def lint():
    return subprocess.run(
        ["bash", str(root / "tests/test-lint.sh"), str(real_repo)],
        capture_output=True, text=True, timeout=10,
    )

completed = lint()
assert completed.returncode == 0, completed.stdout + completed.stderr
entry.write_text(clean.replace("${SOURCED_LIST[@]}", "$SOURCED_LIST"))
completed = lint()
assert completed.returncode != 0, completed.stdout + completed.stderr
assert "SC2128" in completed.stdout, completed.stdout
entry.write_text(clean)
command = real_repo / "dot_local/bin/executable_two words"
command.write_text('#!/usr/bin/env bash\nsource scripts/shared.inc\n'
                   'printf "%s\\n" "$SOURCED_LIST"\n')
completed = lint()
assert completed.returncode != 0, completed.stdout + completed.stderr
assert "SC2128" in completed.stdout, completed.stdout
assert "dot_local/bin/executable_two words" in completed.stdout, completed.stdout

empty_repo = temporary / "empty"
for directory in ("scripts", "tests", "dot_local/bin"):
    (empty_repo / directory).mkdir(parents=True)
completed = subprocess.run(
    ["bash", str(root / "tests/test-lint.sh"), str(empty_repo)],
    input="", capture_output=True, text=True, timeout=10,
)
assert completed.returncode != 0, completed.stdout + completed.stderr
assert "[FAIL] shellcheck" in completed.stderr, completed.stdout + completed.stderr
PY
printf 'Lint wrapper regression tests passed\n'
