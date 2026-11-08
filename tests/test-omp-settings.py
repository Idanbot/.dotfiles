#!/usr/bin/python3
"""Offline retired OMP override cleanup and preservation contracts."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("omp_settings", ROOT / "scripts/omp-settings.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.path = self.root / "settings.json"

    def test_cleanup_preserves_unrelated_settings_and_is_idempotent(self):
        self.path.write_text(json.dumps({
            "dependencies": {"other": "2.0.0"},
            "overrides": {"other": "3.0.0", "@xynogen/pix-pretty": "1.30.0"},
        }))
        self.assertTrue(MODULE.prepare(self.path))
        data = json.loads(self.path.read_text())
        self.assertEqual({"other": "2.0.0"}, data["dependencies"])
        self.assertEqual({"other": "3.0.0"}, data["overrides"])
        self.assertEqual(0o600, self.path.stat().st_mode & 0o777)
        before = self.path.stat()
        self.assertFalse(MODULE.prepare(self.path))
        self.assertEqual(before.st_ino, self.path.stat().st_ino)
        self.assertEqual(before.st_mtime_ns, self.path.stat().st_mtime_ns)

    def test_custom_override_and_absent_settings_are_untouched(self):
        self.assertFalse(MODULE.prepare(self.path))
        self.assertFalse(self.path.exists())
        original = '{"overrides":{"@xynogen/pix-pretty":"1.32.0"}}'
        self.path.write_text(original)
        self.assertFalse(MODULE.prepare(self.path))
        self.assertEqual(original, self.path.read_text())

    def test_empty_override_map_is_removed(self):
        self.path.write_text('{"overrides":{"@xynogen/pix-pretty":"1.30.0"}}')
        self.assertTrue(MODULE.prepare(self.path))
        self.assertEqual({}, json.loads(self.path.read_text()))

    def test_invalid_json_and_shapes_are_preserved(self):
        for original in ("{broken", "[]", '{"overrides":false}', '{"a":1,"a":2}'):
            with self.subTest(original=original):
                self.path.write_text(original)
                with self.assertRaises(ValueError):
                    MODULE.prepare(self.path)
                self.assertEqual(original, self.path.read_text())

    def test_symlink_and_redirected_parent_are_refused(self):
        target = self.root / "target.json"
        target.write_text("{}")
        self.path.symlink_to(target)
        with self.assertRaises(ValueError):
            MODULE.prepare(self.path)
        self.assertEqual("{}", target.read_text())
        directory = self.root / "directory"
        directory.mkdir()
        link = self.root / "link"
        link.symlink_to(directory, target_is_directory=True)
        with self.assertRaises(ValueError):
            MODULE.prepare(link / "settings.json")
        self.assertEqual([], list(directory.iterdir()))

    def test_nonregular_settings_are_refused_without_blocking(self):
        self.path.mkdir()
        with self.assertRaises((OSError, ValueError)):
            MODULE.prepare(self.path)
        self.path.rmdir()
        os.mkfifo(self.path)
        with self.assertRaises(ValueError):
            MODULE.prepare(self.path)
        self.assertTrue(self.path.is_fifo())

    def test_oversized_settings_are_preserved(self):
        original = json.dumps({"padding": "x" * (1024 * 1024)})
        self.path.write_text(original)
        with self.assertRaises(ValueError):
            MODULE.prepare(self.path)
        self.assertEqual(original, self.path.read_text())


if __name__ == "__main__":
    unittest.main()
