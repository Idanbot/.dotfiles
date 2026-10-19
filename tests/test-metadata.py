#!/usr/bin/python3
"""Shared parser, release mapping, and public shell metadata contract tests."""

import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = (
    Path(sys.argv.pop(1)).resolve()
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-")
    else Path(__file__).resolve().parent.parent
)
sys.path.insert(0, str(ROOT / "scripts"))

from dotfiles.metadata import (  # noqa: E402
    MetadataError,
    load_metadata,
    load_repository,
    load_versions,
    release_spec,
    validate_repository,
)


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write(self, name, text):
        path = self.root / name
        path.write_text(text)
        return path

    def cli(self, *args, check=True):
        return subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/dotfiles/metadata.py"),
                *map(str, args),
            ],
            capture_output=True,
            text=True,
            check=check,
        )

    def shell(self, script, **env):
        return subprocess.run(
            ["bash", "-c", 'source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; ' + script],
            env={
                **os.environ,
                "DOTFILES_SOURCE_DIR": str(ROOT),
                "DOTFILES_VERSION_PLAN": "",
                **env,
            },
            capture_output=True,
            text=True,
        )

    def test_scalars_comments_quotes_flow_yaml_and_order(self):
        path = self.write(
            "versions.yaml",
            """second:
  numeric: 01.20
  date: 2026-10-19
  quoted: "1.2#build:7" # actual comment
  escaped: 'don''t-strip'
first: {inline: latest}
""",
        )
        data = load_versions(path)
        self.assertEqual(list(data), ["second", "first"])
        self.assertEqual(list(data["second"]), ["numeric", "date", "quoted", "escaped"])
        self.assertEqual(data["second"]["numeric"], "01.20")
        self.assertEqual(data["second"]["date"], "2026-10-19")
        self.assertEqual(data["second"]["quoted"], "1.2#build:7")
        self.assertEqual(data["second"]["escaped"], "don't-strip")

    def test_invalid_versions_fail_with_path(self):
        fixtures = [
            "",
            "[]",
            "core: []",
            "core: {tool: []}",
            "core: {tool: null}",
            "core: {tool: true}",
            'core: {tool: ""}',
            'core: {tool: "line\\nbreak"}',
            "core: {tool: 1, tool: 2}",
            "core: {}\ncore: {}",
            "core: {tool: 1}\ncore: {other: 2}",
            "core: [",
            "core: {tool: !!python/object:untrusted {}}",
            "? [invalid, key]\n: {}",
            "core: {tool: &recursive {child: *recursive}}",
        ]
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                path = self.write("invalid.yaml", fixture)
                with self.assertRaises(MetadataError) as raised:
                    load_versions(path)
                self.assertIn(str(path), str(raised.exception))

    def test_metadata_integrity_and_coverage_validation(self):
        prefix = "core:\n  tool:\n    source: github\n    owner: dotfiles-binary\n"
        for suffix in (
            "",
            "    integrity: null\n",
            "    integrity: missing\n",
            "    integrity: pinned-sha256\n",
            "    integrity: upstream-checksum\n    sha256: bad\n",
            "    integrity: upstream-checksum\n    repo: []\n",
        ):
            with self.subTest(suffix=suffix):
                with self.assertRaises(MetadataError):
                    load_metadata(self.write("meta.yaml", prefix + suffix))
        digest = "0" * 64
        valid = load_metadata(
            self.write(
                "meta.yaml",
                prefix + f"    integrity: pinned-sha256\n    sha256: {digest}\n",
            )
        )
        self.assertEqual(valid["core"]["tool"]["sha256"], digest)
        versions = {"core": {"tool": "1.2"}}
        self.assertEqual(validate_repository(versions, valid), (versions, valid))
        with self.assertRaisesRegex(MetadataError, "missing metadata"):
            validate_repository(versions, {})
        with self.assertRaisesRegex(MetadataError, "metadata without version"):
            validate_repository({}, valid)

    def test_release_mapping_and_arch_specific_precedence(self):
        meta = {
            "repo": "vendor/tool",
            "tag_template": "tool-v{version}",
            "asset_template": "tool-{tag}-{arch}.zip",
            "arch_amd64": "x64",
            "arch_arm64": "aarch64",
        }
        self.assertEqual(
            release_spec(meta, "v1.2.3", "amd64"),
            {
                "repo": "vendor/tool",
                "tag": "tool-v1.2.3",
                "asset": "tool-tool-v1.2.3-x64.zip",
            },
        )
        meta["asset_template_arm64"] = "tool-{release_arch}.tgz"
        self.assertEqual(
            release_spec(meta, "1.2.3", "arm64")["asset"], "tool-aarch64.tgz"
        )
        for broken in ({"repo": "x/y"}, {**meta, "tag_template": "{unknown}"}):
            with self.assertRaises(MetadataError):
                release_spec(broken, "1", "amd64")
        with self.assertRaises(MetadataError):
            release_spec(meta, "1", "mips")

    def test_repository_release_cli_and_fonts(self):
        versions, metadata = load_repository(ROOT)
        specs = 0
        for section, tools in metadata.items():
            for name, meta in tools.items():
                if not meta.get("tag_template"):
                    continue
                specs += 1
                output = self.cli(
                    "release-spec",
                    ROOT / "packages.meta.yaml",
                    ROOT / "packages.yaml",
                    f"{section}.{name}",
                ).stdout.strip()
                fields = output.split("|")
                self.assertEqual(len(fields), 5)
                self.assertEqual(fields[0], meta["repo"])
                self.assertEqual(fields[1], meta["tag_template"])
                self.assertEqual(
                    fields[2],
                    meta["asset_template"].replace(
                        "{font}", versions["fonts"]["nerd_font"]
                    ),
                )
        self.assertGreater(specs, 20)
        result = self.cli(
            "release-spec",
            ROOT / "packages.meta.yaml",
            ROOT / "packages.yaml",
            "missing.tool",
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Traceback", result.stderr)

    def test_shell_lookup_defaults_overrides_and_invalid_input(self):
        versions = self.write("versions.yaml", 'core: {tool: "v1.2#7"}\n')
        meta = self.write(
            "meta.yaml",
            """core:
  tool: {source: npm, owner: npm, integrity: npm-registry, package: "@vendor/tool#1"}
""",
        )
        result = self.shell(
            "package_version core tool; package_version core absent fallback; "
            "package_metadata core tool package; package_metadata core tool absent fallback",
            DOTFILES_PACKAGES_FILE=str(versions),
            DOTFILES_PACKAGES_META_FILE=str(meta),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            ["v1.2#7", "fallback", "@vendor/tool#1", "fallback"],
        )
        result = self.shell(
            "package_version core tool fallback; package_metadata core tool source fallback",
            DOTFILES_PACKAGES_FILE=str(self.root / "missing"),
            DOTFILES_PACKAGES_META_FILE=str(self.root / "missing-meta"),
        )
        self.assertEqual(result.stdout.splitlines(), ["fallback", "fallback"])
        self.write("versions.yaml", "core: {tool: []}")
        result = self.shell(
            "package_version core tool fallback", DOTFILES_PACKAGES_FILE=str(versions)
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected a nonempty string scalar", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_section_hash_preserves_legacy_section_text_digest(self):
        section = "core:\n  tool: '1'\n\n"
        path = self.write("versions.yaml", section + "other: {tool: '2'}\n")
        before = self.cli("section-hash", path, "core").stdout
        self.assertEqual(before.strip(), hashlib.sha256(section.encode()).hexdigest())
        self.write("versions.yaml", "# comment\n" + section + "other: {tool: '9'}\n")
        self.assertEqual(before, self.cli("section-hash", path, "core").stdout)
        self.write("versions.yaml", "core:\n  tool: '3'\n")
        self.assertNotEqual(before, self.cli("section-hash", path, "core").stdout)

    def test_generators_format_fields_and_validate_before_writing(self):
        versions = self.write("packages.yaml", 'core: {tool: "1.2.3"}\n')
        metadata = self.write(
            "packages.meta.yaml",
            """core:
  tool:
    source: github
    owner: dotfiles-binary
    repo: vendor/tool
    tag_template: "v{version}"
    asset_template: "tool-{arch}.zip"
    arch_amd64: x64
    arch_arm64: aarch64
    integrity: upstream-checksum
""",
        )
        lock = self.root / "packages.lock"
        inventory = self.root / "inventory.md"
        readme = self.write(
            "README.md",
            "before\n<!-- tool-versions:start -->\nold\n<!-- tool-versions:end -->\nafter\n",
        )

        def generate(script, *args):
            return subprocess.run(
                ["bash", str(ROOT / "scripts" / script), *map(str, args)],
                env={**os.environ, "DOTFILES_DIR": str(self.root)},
                text=True,
                capture_output=True,
            )

        result = generate("generate-package-lock.sh", lock)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            lock.read_text(),
            "# packages.lock \u2014 generated from packages.yaml and packages.meta.yaml\n"
            "# Regenerate with: ./scripts/generate-package-lock.sh\n\ngenerated_from:\n"
            f"  packages: {hashlib.sha256(versions.read_bytes()).hexdigest()}\n"
            f"  metadata: {hashlib.sha256(metadata.read_bytes()).hexdigest()}\n\ntools:\n"
            "  - section: core\n    name: tool\n    version: 1.2.3\n    source: github\n"
            '    owner: dotfiles-binary\n    repo: vendor/tool\n    tag_template: "v{version}"\n'
            '    asset_template: "tool-{arch}.zip"\n    arch_amd64: x64\n    arch_arm64: aarch64\n'
            "    integrity: upstream-checksum\n",
        )
        result = generate("generate-tool-inventory.sh", inventory, readme)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(
            inventory.read_text().endswith(
                "| core | tool | 1.2.3 | github | dotfiles-binary | upstream-checksum |\n"
            )
        )
        self.assertEqual(
            readme.read_text(),
            "before\n<!-- tool-versions:start -->\n| Category | Tools and Requested Versions |\n"
            "| --- | --- |\n| core | `tool` 1.2.3 |\n<!-- tool-versions:end -->\nafter\n",
        )
        previous = lock.read_bytes(), inventory.read_bytes(), readme.read_bytes()
        self.write("packages.yaml", "core: {tool: []}\n")
        self.assertNotEqual(generate("generate-package-lock.sh", lock).returncode, 0)
        self.assertNotEqual(
            generate("generate-tool-inventory.sh", inventory, readme).returncode, 0
        )
        self.assertEqual(
            previous, (lock.read_bytes(), inventory.read_bytes(), readme.read_bytes())
        )


if __name__ == "__main__":
    unittest.main()
