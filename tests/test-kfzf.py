#!/usr/bin/env python3
"""Exercise kfzf against synthetic native CLI processes, never real clusters."""

import json
import os
from pathlib import Path
import pty
import select
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "dot_local/bin/executable_kfzf"


class KfzfTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.config = self.home / ".config"
        (self.config / "dotfiles").mkdir(parents=True)
        shutil.copy2(
            ROOT / "dot_config/dotfiles/kfzf.py", self.config / "dotfiles/kfzf.py"
        )
        self.bin = self.home / "bin"
        self.bin.mkdir()
        shutil.copy2(SCRIPT, self.bin / "kfzf")
        (self.bin / "kfzf").chmod(0o755)
        self.calls = self.home / "calls.jsonl"
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "XDG_CACHE_HOME": str(self.home / "cache"),
            "KUBECONFIG": str(self.home / "config"),
            "XDG_CONFIG_HOME": str(self.config),
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "CALLS": str(self.calls),
        }
        (self.home / "config").write_text("synthetic-kubeconfig")
        self.mock(
            "kubectl",
            """import json, os, sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as stream:
    stream.write(json.dumps(args) + '\\n')
if args == ['config', 'current-context']:
    print(os.environ.get('CONTEXT_LABEL', 'sample-context'))
elif args == ['config', 'get-contexts', '-o', 'name']:
    print('sample-context')
elif 'describe' in args:
    if os.environ.get('DESCRIBE_ERROR'):
        print(os.environ['DESCRIBE_ERROR'], file=sys.stderr)
        sys.exit(1)
    print('synthetic description')
elif 'get' in args:
    if os.environ.get('GET_ERROR'):
        print(os.environ['GET_ERROR'], file=sys.stderr)
        sys.exit(1)
    kind = args[args.index('get') + 1]
    namespace = args[args.index('--namespace') + 1] if '--namespace' in args else 'default'
    print(json.dumps({'items': [{'metadata': {'name': 'sample', 'namespace': namespace,
          'annotations': {'private': 'do-not-cache'}}, 'kind': kind}]}))
else:
    sys.exit(3)
""",
        )
        self.mock(
            "fzf",
            """import os, sys
rows = sys.stdin.read().splitlines()
sys.exit(130) if os.environ.get('CANCEL') else None
if rows:
    print(rows[0])
""",
        )

    def mock(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n{body}")
        path.chmod(0o755)

    def run_cli(self, *args, **env):
        return subprocess.run(
            [str(self.bin / "kfzf"), *args],
            env={**self.env, **env},
            text=True,
            capture_output=True,
            timeout=20,
        )

    def calls_for(self, verb):
        return [
            call
            for call in map(json.loads, self.calls.read_text().splitlines())
            if verb in call
        ]

    def test_picker_describes_with_explicit_context_and_prints_command(self):
        result = self.run_cli("-t", "pods")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("full command: kubectl --context sample-context", result.stderr)
        self.assertIn("describe pods sample --namespace default", result.stderr)
        self.assertIn("synthetic description", result.stdout)
        self.assertEqual(len(self.calls_for("describe")), 1)

    def cache_files(self):
        return list((self.home / "cache/dotfiles/kfzf").glob("*.json"))

    def test_cache_hit_and_ttl_by_resource(self):
        for resource, age, expires in [
            ("pods", 86401, True),
            ("deployments", 30 * 86400, False),
            ("deployments", 32 * 86400, True),
            ("namespaces", 99999999, False),
        ]:
            with self.subTest(resource=resource, age=age):
                args = (
                    ("--complete", "namespaces")
                    if resource == "namespaces"
                    else ("--complete", "resources", "-t", resource)
                )
                self.assertEqual(self.run_cli(*args).returncode, 0)
                record_path = next(
                    p
                    for p in self.cache_files()
                    if json.loads(p.read_text())["resource_type"] == resource
                )
                record = json.loads(record_path.read_text())
                record["timestamp"] = time.time() - age
                record_path.write_text(json.dumps(record))
                before = len(self.calls_for("get"))
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.calls_for("get")), before + int(expires))

    def test_not_found_marks_cache_then_next_invocation_refreshes(self):
        self.assertEqual(self.run_cli("--complete", "namespaces").returncode, 0)
        self.assertEqual(
            self.run_cli("--complete", "resources", "-t", "pods").returncode, 0
        )
        result = self.run_cli(
            "default/pods/sample",
            DESCRIBE_ERROR='Error from server (NotFound): pods "sample" not found',
        )
        self.assertEqual(result.returncode, 1)
        self.assertTrue(
            all(json.loads(p.read_text())["failed"] for p in self.cache_files())
        )
        before = len(self.calls_for("get"))
        self.assertEqual(self.run_cli("-t", "pods").returncode, 0)
        self.assertEqual(len(self.calls_for("get")), before + 1)
        pod = next(
            json.loads(p.read_text())
            for p in self.cache_files()
            if json.loads(p.read_text())["resource_type"] == "pods"
            and json.loads(p.read_text())["namespace"] is None
        )
        self.assertFalse(pod["failed"])

    def test_auth_errors_visible_and_do_not_mark_missing(self):
        self.assertEqual(self.run_cli("-t", "pods").returncode, 0)
        result = self.run_cli(
            "default/pods/sample", DESCRIBE_ERROR="Forbidden: credentials expired"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Forbidden", result.stderr)
        self.assertFalse(json.loads(self.cache_files()[0].read_text())["failed"])
        result = self.run_cli("-t", "nodes", GET_ERROR="Unauthorized")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Unauthorized", result.stderr)

    def test_contexts_no_ttl_and_explicit_refresh(self):
        self.assertEqual(
            self.run_cli("--complete", "contexts").stdout.strip(), "sample-context"
        )
        path = self.cache_files()[0]
        record = json.loads(path.read_text())
        record["timestamp"] = 0
        path.write_text(json.dumps(record))
        self.run_cli("--complete", "contexts")
        self.assertEqual(len(self.calls_for("get-contexts")), 1)
        self.run_cli("--complete", "contexts", "--refresh")
        self.assertEqual(len(self.calls_for("get-contexts")), 2)

    def test_scope_isolation_and_private_metadata(self):
        for args in [("-n", "one"), ("-n", "two"), ("--context", "other")]:
            result = self.run_cli("--complete", "resources", "-t", "pods", *args)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.cache_files()), 3)
        for path in self.cache_files():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            record = json.loads(path.read_text())
            self.assertEqual(set(record["items"][0]), {"name", "namespace", "type"})
            self.assertIn("fetched_at", record)
            self.assertNotIn("synthetic-kubeconfig", path.read_text())
            self.assertNotIn("do-not-cache", path.read_text())
        self.assertEqual(self.cache_files()[0].parent.stat().st_mode & 0o777, 0o700)
        (self.home / "config").write_text("changed synthetic config")
        self.run_cli("--complete", "resources", "-t", "pods")
        self.assertEqual(len(self.cache_files()), 4)

    def test_cancel_and_invalid_flags_never_describe(self):
        self.assertEqual(self.run_cli("-t", "pods", CANCEL="1").returncode, 0)
        self.assertEqual(len(self.calls_for("describe")), 0)
        for args in [
            ("-n",),
            ("-t",),
            ("--unknown",),
            ("one", "two"),
            ("default/pods/a/extra",),
            ("--namespace", ""),
            ("default/pods/sample", "--namespace", "other"),
        ]:
            self.assertNotEqual(self.run_cli(*args).returncode, 0)
        self.assertEqual(len(self.calls_for("describe")), 0)

    def test_cluster_scope_and_namespace_named_cluster(self):
        for target in [
            "_/nodes/sample",
            "cluster/pods/sample",
            "_/clusterroles/system:node",
        ]:
            result = self.run_cli(target, "--context", "explicit")
            self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls_for("describe")
        self.assertNotIn("--namespace", calls[0])
        self.assertIn("--namespace", calls[1])
        self.assertTrue(all(call[:2] == ["--context", "explicit"] for call in calls))

    def test_preview_uses_bounded_no_event_command_and_marks_cache(self):
        self.run_cli("-t", "pods")
        result = self.run_cli(
            "--preview", "default/pods/sample", DESCRIBE_ERROR="NotFound"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("full command:", result.stderr)
        self.assertIn("--show-events=false", self.calls_for("describe")[-1])
        self.assertIn("--request-timeout=8s", self.calls_for("describe")[-1])

    def test_corrupt_cache_is_refetched(self):
        self.run_cli("-t", "pods")
        self.cache_files()[0].write_text("{broken json")
        self.assertEqual(self.run_cli("-t", "pods").returncode, 0)
        self.assertEqual(len(self.calls_for("get")), 2)

    def shell(self, code):
        return subprocess.run(
            ["zsh", "-dfc", code],
            text=True,
            capture_output=True,
            env={**self.env, "ROOT": str(ROOT)},
            timeout=20,
        )

    def test_completion_forwards_scope_and_returns_insertable_tokens(self):
        result = self.shell("""
            _arguments() { state=resources; opt_args=(--context chosen -n one -t pods); }
            _wanted() { print -rl -- "${values[@]}"; }
            fpath=("$ROOT/dot_zsh/completions" $fpath)
            autoload -Uz _kfzf
            _kfzf
        """)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "one/pods/sample")
        call = self.calls_for("get")[0]
        self.assertEqual(call[:2], ["--context", "chosen"])
        self.assertIn("one", call)
        self.assertNotIn("full command:", result.stdout)

    def test_preview_style_preserves_bindings_and_has_no_startup_requests(self):
        result = self.shell("""
            zstyle ':fzf-tab:*' fzf-flags '--ansi' '--bind=tab:accept'
            source "$ROOT/dot_config/zsh/kfzf.zsh"
            zstyle -a ':fzf-tab:complete:kfzf:*' fzf-flags flags
            print -rl -- "${flags[@]}"
        """)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--bind=tab:accept", result.stdout)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.cache_files())
        result = self.shell("""
            source "$ROOT/dot_config/zsh/kfzf.zsh"
            words=(kfzf --context chosen --namespace default)
            word=default/pods/sample
            zstyle -s ':fzf-tab:complete:kfzf:*' fzf-preview preview
            eval "$preview"
        """)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("full command: kubectl --context chosen", result.stdout)
        self.assertIn("synthetic description", result.stdout)

    def test_multi_type_results_and_refresh(self):
        args = ("--complete", "resources", "-t", "pods,deployments,pods")
        result = self.run_cli(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 2)
        self.assertEqual(len(self.calls_for("get")), 2)
        self.assertEqual(self.run_cli(*args).returncode, 0)
        self.assertEqual(len(self.calls_for("get")), 2)
        self.assertEqual(self.run_cli(*args, "--refresh").returncode, 0)
        self.assertEqual(len(self.calls_for("get")), 4)

    def test_direct_missing_resource_leaves_a_failed_cache_record(self):
        result = self.run_cli("default/pods/missing", DESCRIBE_ERROR="NotFound")
        self.assertEqual(result.returncode, 1)
        self.assertTrue(self.cache_files())
        self.assertTrue(
            all(json.loads(path.read_text())["failed"] for path in self.cache_files())
        )

    def test_failed_discovery_is_retried_without_ttl_wait(self):
        self.assertEqual(self.run_cli("-t", "pods", GET_ERROR="NotFound").returncode, 1)
        self.assertTrue(json.loads(self.cache_files()[0].read_text())["failed"])
        self.assertEqual(self.run_cli("-t", "pods").returncode, 0)
        self.assertFalse(json.loads(self.cache_files()[0].read_text())["failed"])

    def test_real_zsh_tab_completion_in_disposable_terminal(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe(
                "zsh", ["zsh", "-df"], {**self.env, "ROOT": str(ROOT), "TERM": "xterm"}
            )
        output = b""

        def until(marker):
            nonlocal output
            deadline = time.monotonic() + 12
            while marker not in output and time.monotonic() < deadline:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        output += os.read(fd, 65536)
                    except OSError:
                        break
            self.assertIn(marker, output, output.decode(errors="replace"))

        try:
            os.write(
                fd,
                b'fpath=("$ROOT/dot_zsh/completions" $fpath)\nautoload -Uz compinit\ncompinit -D -u\n_capture() { print -r -- "KFZF_CAPTURE:$BUFFER"; exit; }\nzle -N _capture\nbindkey "^X" _capture\nPROMPT="KFZF_READY> "\n',
            )
            until(b"KFZF_READY> ")
            output = b""
            os.write(fd, b"kfzf -t pods sa\t")
            time.sleep(0.6)
            os.write(fd, b"\x18")
            until(b"KFZF_CAPTURE:kfzf -t pods default/pods/sample")
        finally:
            os.close(fd)
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)


if __name__ == "__main__":
    unittest.main()
