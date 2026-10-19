#!/usr/bin/env python3
"""Regressions for the reusable graph and its fail-closed final check."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = (
    Path(sys.argv.pop(1)).resolve()
    if len(sys.argv) > 1
    else Path(__file__).resolve().parents[1]
)
sys.path.insert(0, str(ROOT / "scripts/ci"))
import contracts  # noqa: E402

spec = importlib.util.spec_from_file_location(
    "ci_result", ROOT / "scripts/ci/result.py"
)
result = importlib.util.module_from_spec(spec)
spec.loader.exec_module(result)


class GraphTests(unittest.TestCase):
    def test_repository_contracts(self):
        contracts.check(ROOT)

    def test_graph_mutations_are_rejected(self):
        mutations = [
            ("ci.yml", lambda wf: wf["jobs"]["live"].update(needs=[])),
            ("ci.yml", lambda wf: wf["jobs"]["result"].update(needs=["checks"])),
            (
                "ci-live.yml",
                lambda wf: wf["jobs"]["heavy-e2e"].update(**{"if": "false"}),
            ),
            ("ci-live.yml", lambda wf: wf["jobs"]["base-e2e"].pop("timeout-minutes")),
            ("ci-outcome.yml", lambda wf: wf["jobs"]["classify"].pop("if")),
        ]
        for filename, mutate in mutations:
            with (
                self.subTest(filename=filename),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                shutil.copytree(ROOT / ".github", root / ".github")
                path = root / ".github/workflows" / filename
                workflow = contracts.load(path)
                mutate(workflow)
                path.write_text(contracts.yaml.safe_dump(workflow))
                with self.assertRaises((AssertionError, KeyError)):
                    contracts.check(root)

    def test_required_results(self):
        self.assertEqual(result.failures({"checks": {"result": "success"}}), [])
        for conclusion in ("failure", "cancelled", "skipped", "timed_out", None):
            with self.subTest(conclusion=conclusion):
                self.assertTrue(result.failures({"checks": {"result": conclusion}}))

    def test_only_expected_skips_are_allowed(self):
        self.assertEqual(
            result.failures({"heavy": {"result": "skipped"}}, ["heavy"]), []
        )
        self.assertTrue(result.failures({"heavy": {"result": "failure"}}, ["heavy"]))
        self.assertTrue(result.failures({"base": {"result": "skipped"}}, ["heavy"]))

    def test_missing_required_result_is_fatal(self):
        completed = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/ci/result.py"),
                "--required",
                "checks",
                "live",
            ],
            env={
                **os.environ,
                "CI_NEEDS": json.dumps({"checks": {"result": "success"}}),
            },
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("live: missing", completed.stderr)

    def test_e2e_cleanup_is_scoped_to_its_own_project(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mock = root / "docker"
            calls = root / "calls"
            mock.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >>"$MOCK_CALLS"\n')
            mock.chmod(0o755)
            env = {
                **os.environ,
                "PATH": str(root) + ":" + os.environ["PATH"],
                "MOCK_CALLS": str(calls),
            }
            for _ in range(2):
                subprocess.run(
                    ["bash", str(ROOT / "scripts/ci/e2e.sh"), "base-native"],
                    cwd=root,
                    env=env,
                    check=True,
                )
            lines = calls.read_text().splitlines()
            self.assertEqual(len(lines), 4)
            projects = [line.split()[2] for line in lines]
            self.assertEqual(projects[0], projects[1])
            self.assertEqual(projects[2], projects[3])
            self.assertNotEqual(projects[0], projects[2])
            self.assertTrue(
                all(line.startswith("compose -p dotfiles-ci-") for line in lines)
            )


if __name__ == "__main__":
    unittest.main()
