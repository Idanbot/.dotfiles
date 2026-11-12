#!/usr/bin/env python3
"""Exercise real tmux targeting without attaching a test client."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid


ROOT = Path(sys.argv.pop(1)).resolve()


class ProjectIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tmux-identity-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.socket = f"identity-{uuid.uuid4().hex[:12]}"
        self.env = {
            "PATH": f"{self.home}/bin:/usr/bin:/bin",
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "SHELL": "/bin/bash",
            "LANG": "C.UTF-8",
            "TEST_SOCKET": self.socket,
        }
        self.addCleanup(self.stop_server)
        (self.home / "bin").mkdir()
        self.write_command("tmux", '''#!/bin/bash
set -euo pipefail
case "$1" in
  attach-session | switch-client)
    /usr/bin/tmux -L "$TEST_SOCKET" display-message -p -t "${3}:" '#{session_path}' ;;
  display-message)
    [[ "${BLOCK_QUERY:-false}" != true ]] || exit 1
    exec /usr/bin/tmux -L "$TEST_SOCKET" "$@" ;;
  *) exec /usr/bin/tmux -L "$TEST_SOCKET" -f /dev/null "$@" ;;
esac
''')
        self.write_command("uvx", "#!/bin/sh\nexit 97\n")
        config = self.home / ".config"
        (config / "dotfiles").mkdir(parents=True)
        (config / "tmuxp").mkdir()
        shutil.copyfile(ROOT / "agents.yaml", config / "dotfiles/agents.yaml")
        shutil.copyfile(ROOT / "dot_config/tmuxp/agent-workspace.yaml",
                        config / "tmuxp/agent-workspace.yaml")
        source = (ROOT / "dot_local/bin/executable_tmux-sessionizer.tmpl").read_text()
        self.sessionizer = self.write_command(
            "sessionizer", source.replace('{{ .sessionizer_dirs | quote }}', '"~/Code ~/Scripts"'))
        self.workspace = ROOT / "dot_local/bin/executable_dot-workspace"

    def stop_server(self):
        subprocess.run(["/usr/bin/tmux", "-L", self.socket, "kill-server"],
                       env=self.env, capture_output=True, timeout=5, check=False)

    def write_command(self, name, text):
        path = self.home / "bin" / name
        path.write_text(text)
        path.chmod(0o700)
        return path

    def run_command(self, *args, success=True):
        result = subprocess.run([str(arg) for arg in args], cwd=self.home,
                                env=self.env, capture_output=True, text=True, timeout=10)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result.stdout.strip()

    def project(self, name):
        path = self.home / name
        path.mkdir(parents=True)
        return path

    def create_session(self, name, directory, window="terminal"):
        self.run_command("tmux", "new-session", "-d", "-s", name, "-n", window,
                         "-c", directory, "sleep 120")

    def snapshot(self):
        return self.run_command("tmux", "list-panes", "-a", "-F",
                                "#{session_id}|#{pane_id}|#{pane_pid}|#{session_path}")

    def test_workspace_reuse_and_plan_target_the_exact_session(self):
        project = self.project("project with spaces")
        other = self.project("other")
        self.create_session("review", project)
        self.create_session("decoy", other, window="review")
        before = self.snapshot()
        for nested in (False, True):
            if nested:
                self.env["TMUX"] = "synthetic-client"
            self.assertEqual(self.run_command("bash", self.workspace, project,
                                             "--name", "review"), str(project))
        plan = json.loads(self.run_command("bash", self.workspace, project,
                                          "--name", "review", "--plan"))
        self.assertEqual(plan["observation"], "available")
        self.assertFalse(plan["mutates"])
        self.run_command("bash", self.workspace, other, "--name", "review", success=False)
        self.env["BLOCK_QUERY"] = "true"
        self.run_command("bash", self.workspace, project, "--name", "review", success=False)
        plan = json.loads(self.run_command("bash", self.workspace, project,
                                          "--name", "review", "--plan"))
        self.assertEqual(plan["observation"], "directory-unverified")
        self.assertEqual(self.snapshot(), before)

    def test_sessionizer_separates_collisions_and_reuses_aliases(self):
        paths = [self.project(name) for name in
                 ("Code/api", "Scripts/api", "Code/a.b", "Code/a b")]
        for path in paths:
            self.assertEqual(self.run_command("bash", self.sessionizer, path), str(path))
        before = self.snapshot()
        alias = self.home / "alias"
        alias.symlink_to(paths[0], target_is_directory=True)
        for path in [*paths, alias]:
            self.assertEqual(self.run_command("bash", self.sessionizer, path), str(path.resolve()))
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(len(before.splitlines()), 4)
        self.env["BLOCK_QUERY"] = "true"
        self.run_command("bash", self.sessionizer, paths[0], success=False)
        self.assertEqual(self.snapshot(), before)

    def test_sessionizer_preserves_legacy_sessions(self):
        first = self.project("Code/api")
        second = self.project("Scripts/api")
        self.create_session("api_", first)
        before = self.snapshot()
        self.assertEqual(self.run_command("bash", self.sessionizer, first), str(first))
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.run_command("bash", self.sessionizer, second), str(second))
        self.assertIn(before, self.snapshot())
        self.assertEqual(len(self.snapshot().splitlines()), 2)


unittest.main()
