#!/usr/bin/env python3
"""Exercise inactive Node and Java publication with the real installer blocks."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / ".chezmoiscripts/run_once_04-install-languages.sh.tmpl").read_text()
PINS = {"node": "26.13.0", "java": "25.0.5+8"}


class RuntimeCandidateTests(unittest.TestCase):
    def run_candidate(self, tool, scenario):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            root = home / ".local/share/dotfiles/tools" / tool / PINS[tool]
            root.parent.mkdir(parents=True)
            payload = root
            if scenario == "redirected-root":
                payload = home / "external"
                root.symlink_to(payload, target_is_directory=True)
            elif scenario == "redirected-parent":
                root.parent.rmdir()
                (home / "external").mkdir()
                root.parent.symlink_to(home / "external", target_is_directory=True)
            bindir = home / ".local/bin"
            bindir.mkdir(parents=True)
            env = {
                "HOME": directory, "PATH": f"{bindir}:/usr/bin:/bin",
                "DOTFILES_SOURCE_DIR": str(ROOT), "DOTFILES_STATE_DIR": str(home / "state"),
                "ROOT": str(root), "TOOL": tool, "PIN": PINS[tool], "NO_COLOR": "1",
            }
            start, end = (("NODE_VERSION=", "TYPESCRIPT_VERSION=") if tool == "node"
                          else ("JAVA_VERSION=", "print_summary"))
            block = SOURCE[SOURCE.index(start):SOURCE.index(end)]

            def shell(code):
                return subprocess.run(
                    ["bash", "-ec", 'source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; ' + code],
                    env=env, text=True, capture_output=True, timeout=20,
                )

            if scenario != "missing":
                (payload / "bin").mkdir(parents=True)
                executable = payload / "bin" / tool
                actual = PINS[tool]
                if scenario == "wrong-version":
                    actual = "26.14.0" if tool == "node" else "25.0.4+9"
                if scenario == "wrong-build":
                    actual = "25.0.5+7"
                output = (f"v{actual}" if tool == "node" else
                          f"    java.runtime.version = {actual}-LTS")
                redirect = " >&2" if tool == "java" else ""
                executable.write_text(f'#!/bin/sh\ntouch "$HOME/probed"\necho "{output}"{redirect}\n')
                executable.chmod(0o755)
                if scenario == "redirected-executable":
                    destination = home / "external-executable"
                    executable.rename(destination)
                    executable.symlink_to(destination)
                if tool == "node":
                    npm = payload / "bin/npm"
                    npm.write_text("#!/bin/sh\necho 12.2.2\n")
                    npm.chmod(0o755)
                if scenario != "unowned":
                    recorded = shell('record_install "$TOOL" "$PIN" fixture "$ROOT"')
                    self.assertEqual(recorded.returncode, 0, recorded.stderr)
                if scenario == "modified":
                    (root / "local-change").write_text("preserve")
            state = home / "state"

            def receipts():
                return {path.relative_to(state): path.read_bytes()
                        for path in state.rglob("*") if path.is_file()}

            before = receipts()
            setup = ('ARCH=amd64; package_version() { '
                     'if [[ "$2" == npm ]]; then echo 12.2.2; else echo "$PIN"; fi; }; '
                     'download_verified() { touch "$HOME/download"; exit 99; }; ')
            result = shell(setup + block)
            if scenario == "verified":
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((bindir / tool).resolve(), root / "bin" / tool)
                before = receipts()
                second = shell(setup + 'managed_link() { exit 98; }; ' + block)
                self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
                self.assertEqual(receipts(), before)
            else:
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(receipts(), before)
                self.assertFalse(os.path.lexists(bindir / tool))
                self.assertFalse(os.path.lexists(root.parent / "current"))
                self.assertEqual((home / "probed").exists(), scenario in {"wrong-version", "wrong-build"})
            self.assertEqual((home / "download").exists(), scenario == "missing")

    def test_inactive_runtime_candidates(self):
        for tool in PINS:
            scenarios = ["unowned", "modified", "redirected-root", "redirected-parent", "redirected-executable",
                         "wrong-version", "missing", "verified"]
            if tool == "java":
                scenarios.append("wrong-build")
            for scenario in scenarios:
                with self.subTest(tool=tool, scenario=scenario):
                    self.run_candidate(tool, scenario)


if __name__ == "__main__":
    unittest.main()
