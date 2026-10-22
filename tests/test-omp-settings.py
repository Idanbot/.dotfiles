#!/usr/bin/python3
"""Offline OMP compatibility and Pix state preservation contracts."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "omp_settings", ROOT / "scripts/omp-settings.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.path = self.root / "settings.json"
        self.overrides = {"@xynogen/pix-pretty": "1.30.0"}

    def test_plugin_overrides_preserve_other_choices_and_are_idempotent(self):
        self.path.write_text(
            json.dumps(
                {"dependencies": {"other": "2.0.0"}, "overrides": {"other": "3.0.0"}}
            )
        )
        self.assertTrue(MODULE.prepare(self.path, "plugins", self.overrides))
        data = json.loads(self.path.read_text())
        self.assertEqual("2.0.0", data["dependencies"]["other"])
        self.assertEqual("3.0.0", data["overrides"]["other"])
        self.assertEqual("1.30.0", data["overrides"]["@xynogen/pix-pretty"])
        self.assertEqual(0o600, self.path.stat().st_mode & 0o777)
        before = self.path.stat()
        self.assertFalse(MODULE.prepare(self.path, "plugins", self.overrides))
        self.assertEqual(before.st_ino, self.path.stat().st_ino)
        self.assertEqual(before.st_mtime_ns, self.path.stat().st_mtime_ns)

    def test_conflicting_override_is_never_replaced(self):
        original = '{"overrides":{"@xynogen/pix-pretty":"1.32.0"}}'
        self.path.write_text(original)
        with self.assertRaises(ValueError):
            MODULE.prepare(self.path, "plugins", self.overrides)
        self.assertEqual(original, self.path.read_text())

    def test_invalid_json_and_shapes_are_preserved(self):
        for original in ("{broken", "[]", '{"overrides":false}', '{"a":1,"a":2}'):
            with self.subTest(original=original):
                self.path.write_text(original)
                with self.assertRaises(ValueError):
                    MODULE.prepare(self.path, "plugins", self.overrides)
                self.assertEqual(original, self.path.read_text())

    def test_symlinks_and_nonregular_files_are_refused(self):
        target = self.root / "target.json"
        target.write_text("{}")
        self.path.symlink_to(target)
        with self.assertRaises(ValueError):
            MODULE.prepare(self.path, "plugins", self.overrides)
        self.assertTrue(self.path.is_symlink())
        self.assertEqual("{}", target.read_text())
        target.unlink()
        with self.assertRaises(ValueError):
            MODULE.prepare(self.path, "plugins", self.overrides)
        self.path.unlink()
        self.path.mkdir()
        with self.assertRaises((ValueError, OSError)):
            MODULE.prepare(self.path, "plugins", self.overrides)

    def test_redirected_parent_is_refused(self):
        target = self.root / "target"
        target.mkdir()
        link = self.root / "link"
        link.symlink_to(target, target_is_directory=True)
        with self.assertRaises(ValueError):
            MODULE.prepare(link / "settings.json", "plugins", self.overrides)
        self.assertEqual([], list(target.iterdir()))

    def test_new_optimizer_defaults_are_off_and_partial_choices_preserved(self):
        MODULE.prepare(self.path, "optimizer")
        self.assertEqual(
            {"optimizer": dict.fromkeys(("caveman", "rtk", "ponytail"), "off")},
            json.loads(self.path.read_text()),
        )
        self.path.write_text('{"other":true,"optimizer":{"caveman":"full"}}')
        MODULE.prepare(self.path, "optimizer")
        data = json.loads(self.path.read_text())
        self.assertTrue(data["other"])
        self.assertEqual(
            {"caveman": "full", "rtk": "off", "ponytail": "off"}, data["optimizer"]
        )

    def test_legacy_state_is_copied_without_removing_or_overriding_choices(self):
        legacy = self.root / "optimizer.json"
        original = '{"caveman":"lite","rtk":"on","ponytail":"full"}'
        legacy.write_text(original)
        self.path.write_text('{"optimizer":{"rtk":"off"}}')
        MODULE.prepare(self.path, "optimizer", legacy=legacy)
        data = json.loads(self.path.read_text())["optimizer"]
        self.assertEqual({"caveman": "lite", "rtk": "off", "ponytail": "full"}, data)
        self.assertEqual(original, legacy.read_text())
        before = self.path.read_bytes()
        self.assertFalse(MODULE.prepare(self.path, "optimizer", legacy=legacy))
        self.assertEqual(before, self.path.read_bytes())

    def test_invalid_legacy_state_does_not_create_settings(self):
        legacy = self.root / "optimizer.json"
        legacy.write_text('{"rtk":true}')
        with self.assertRaises(ValueError):
            MODULE.prepare(self.path, "optimizer", legacy=legacy)
        self.assertFalse(self.path.exists())


if __name__ == "__main__":
    unittest.main()
