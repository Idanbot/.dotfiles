#!/usr/bin/env python3
"""Registry completeness, standalone planning parity, and helper-only routing."""

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
SPEC = importlib.util.spec_from_file_location(
    "section_state", ROOT / "scripts/section-state.py"
)
STATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STATE)


class RegistryTests(unittest.TestCase):
    def test_embedded_registry_is_current(self):
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/section-registry.py"),
                "--source",
                str(ROOT),
                "--check",
            ],
            check=True,
        )

    def test_all_install_sections_have_unique_scripts_and_commands(self):
        entries = STATE.registry(ROOT)
        scripts = [entry["script"] for entry in entries.values()]
        self.assertEqual(len(scripts), len(set(scripts)))
        self.assertEqual(
            set(scripts),
            {
                str(path.relative_to(ROOT))
                for path in (ROOT / ".chezmoiscripts").glob("*.tmpl")
                if "-install-" in path.name
                or path.name
                in {
                    "run_once_before_00-detect-environment.sh.tmpl",
                    "run_once_12-configure-system.sh.tmpl",
                    "run_once_13-apply-catppuccin-theme.sh.tmpl",
                    "run_once_after_enable-services.sh.tmpl",
                }
            },
        )
        for entry in entries.values():
            self.assertTrue(
                set(entry.get("stable_commands", [])) <= set(entry["commands"])
            )
            self.assertFalse(
                set(entry.get("optional_commands", [])) & set(entry["commands"])
            )

    def test_standalone_and_file_backed_plans_match(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {
                **os.environ,
                "HOME": directory,
                "DOTFILES_SOURCE_OVERRIDE": "",
                "DOTFILES_COLOR": "never",
            }
            selections = [
                ["--profile", path.stem]
                for path in sorted((ROOT / "profiles").glob("*.conf"))
            ]
            selections += [
                [],
                ["--with=ai,tmux,media"],
                ["--with", "history"],
                ["--full", "--without=cloud,vscode"],
                ["--sections=media,core,ai"],
                ["--with=ai", "--without=languages"],
                ["--sections=no-such-section"],
            ]
            for arguments in selections:
                with self.subTest(arguments=arguments):
                    file_plan = subprocess.run(
                        [
                            "bash",
                            str(ROOT / "scripts/install.sh"),
                            *arguments,
                            "--print-plan",
                        ],
                        cwd=directory,
                        env=env,
                        capture_output=True,
                        text=True,
                    )
                    standalone = subprocess.run(
                        ["bash", "-s", "--", *arguments, "--print-plan"],
                        input=(ROOT / "scripts/install.sh").read_text(),
                        cwd=directory,
                        env=env,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(
                        (file_plan.returncode, file_plan.stdout, file_plan.stderr),
                        (standalone.returncode, standalone.stdout, standalone.stderr),
                    )

    def test_alternate_source_controls_registry_and_profiles(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            alternate = temporary / "alternate checkout"
            (alternate / "scripts").mkdir(parents=True)
            shutil.copyfile(
                ROOT / "scripts/section-registry.py",
                alternate / "scripts/section-registry.py",
            )
            shutil.copytree(ROOT / ".chezmoiscripts", alternate / ".chezmoiscripts")
            shutil.copytree(ROOT / "profiles", alternate / "profiles")
            entries = json.loads((ROOT / "scripts/sections.json").read_text())
            entries["terminal"]["order"], entries["zsh"]["order"] = (
                entries["zsh"]["order"],
                entries["terminal"]["order"],
            )
            entries["alternate"] = {**entries["detect"], "order": 15}
            entries["ai"]["dependencies"] = ["history"]
            (alternate / "scripts/sections.json").write_text(json.dumps(entries))
            order = sorted(entries, key=lambda name: entries[name]["order"])
            for path in (alternate / "profiles").glob("*.conf"):
                lines = path.read_text().splitlines()
                sections = next(
                    line.removeprefix("sections=")
                    for line in lines
                    if line.startswith("sections=")
                ).split(",")
                if path.stem in {"base", "full"}:
                    sections.append("alternate")
                sections = [name for name in order if name in sections]
                path.write_text(
                    "\n".join(
                        "sections=" + ",".join(sections)
                        if line.startswith("sections=") else line
                        for line in lines
                    ) + "\n"
                )
            env = {
                **os.environ, "HOME": directory,
                "DOTFILES_SOURCE_OVERRIDE": "", "DOTFILES_COLOR": "never",
            }
            base = "detect,core,alternate,terminal,zsh"
            cases = [
                (["--profile", "base"], base),
                (["--with=ai"], base + ",history,ai"),
                (["--sections=terminal,alternate,core"], "core,alternate,terminal"),
                (["--only", "alternate"], "alternate"),
            ]
            for source_args in (
                ["--source", str(alternate)], [f"--source={alternate}"]
            ):
                for selection, expected in cases:
                    for arguments in (
                        source_args + selection, selection + source_args
                    ):
                        for stdin in (False, True):
                            with self.subTest(arguments=arguments, stdin=stdin):
                                command = (
                                    ["bash", "-s", "--"] if stdin
                                    else ["bash", str(ROOT / "scripts/install.sh")]
                                )
                                result = subprocess.run(
                                    [*command, *arguments, "--print-plan"],
                                    input=(ROOT / "scripts/install.sh").read_text()
                                    if stdin else None,
                                    cwd=directory, env=env,
                                    capture_output=True, text=True,
                                )
                                self.assertEqual(0, result.returncode, result.stderr)
                                self.assertIn(
                                    "sections=" + expected, result.stdout.splitlines()
                                )

    def test_helper_only_changes_route_to_their_consumers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("scripts", ".chezmoiscripts", "profiles"):
                shutil.copytree(
                    ROOT / name,
                    root / name,
                    ignore=shutil.ignore_patterns("__pycache__"),
                )
            for name in (
                "packages.yaml",
                "packages.meta.yaml",
                ".chezmoiexternal.yaml",
            ):
                shutil.copyfile(ROOT / name, root / name)
            sections = STATE.registry(root)

            def changed_by(filename, payload):
                before = {name: STATE.fingerprint(root, name) for name in sections}
                path = root / filename
                original = path.read_bytes() if path.is_file() else None
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
                changed = {
                    name
                    for name in sections
                    if STATE.fingerprint(root, name) != before[name]
                }
                if original is None:
                    path.unlink()
                else:
                    path.write_bytes(original)
                return changed

            apt = {
                name
                for name, entry in sections.items()
                if "scripts/hashicorp-keyrings.py" in entry["shared_inputs"]
            }
            self.assertEqual(
                apt,
                changed_by("scripts/hashicorp-keyrings.py", b"# helper-only change\n"),
            )
            self.assertTrue(
                {"core", "cloud", "zsh", "terminal", "tmux", "media", "desktop"} <= apt
            )
            self.assertNotIn("languages", apt)
            self.assertEqual(
                set(sections),
                changed_by("scripts/lib/future-helper.sh", b"# new loaded helper\n"),
            )
            runtime = {name for name, entry in sections.items() if entry["manifest"]}
            self.assertEqual(
                runtime,
                changed_by("scripts/dotfiles/future.py", b"# new runtime module\n"),
            )
            self.assertEqual(
                runtime, changed_by("scripts/catalog.py", b"# changed shared probe\n")
            )
            for filename in (
                "scripts/dotfiles/metadata.py",
                "scripts/dotfiles/releases.py",
                "scripts/dotfiles/__init__.py",
            ):
                self.assertEqual(
                    runtime, changed_by(filename, b"# changed runtime module\n")
                )
            self.assertEqual(
                {"ai", "media"},
                changed_by("scripts/install-uv-tool.sh", b"# uv helper change\n"),
            )
            self.assertEqual(
                set(), changed_by("requirements-audit.txt", b"audit-only dependency\n")
            )
            policies = json.loads((root / "scripts/update-policy.json").read_text())
            policies["languages.node"] = "changed-policy"
            self.assertEqual(
                {"languages"},
                changed_by("scripts/update-policy.json", json.dumps(policies).encode()),
            )
            policies["ai_tools.bun"] = "another-policy"
            self.assertEqual(
                {"languages", "ai"},
                changed_by("scripts/update-policy.json", json.dumps(policies).encode()),
            )

    def test_registry_rejects_cyclic_or_out_of_order_dependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / ".chezmoiscripts", root / ".chezmoiscripts")
            (root / "scripts").mkdir()
            entries = json.loads((ROOT / "scripts/sections.json").read_text())
            entries["languages"]["dependencies"] = ["ai"]
            (root / "scripts/sections.json").write_text(json.dumps(entries))
            with self.assertRaisesRegex(ValueError, "dependency must precede"):
                STATE.registry(root)


if __name__ == "__main__":
    unittest.main()
