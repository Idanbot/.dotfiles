#!/usr/bin/env python3
"""Exercise parsed YAML edits through the actual upgrade-plan module."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = (
    Path(sys.argv.pop(1)).resolve()
    if len(sys.argv) > 1
    else Path(__file__).resolve().parents[1]
)
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location(
    "apply_plan", ROOT / "scripts/apply-package-plan.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ApplyPlanTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.paths = [
            self.root / name
            for name in ("packages.yaml", "metadata.yaml", "externals.yaml", "plan.tsv")
        ]
        self.paths[0].write_text(
            '# keep this comment\ncore: {demo: "1.0.0", other: "2.0.0"} # keep order\n'
        )
        self.paths[1].write_text(
            "core:\n  demo:\n    source: github\n    owner: dotfiles-binary\n    integrity: pinned-sha256\n    sha256: "
            + "a" * 64
            + "\n"
        )
        self.paths[2].write_text("# untouched external configuration\n{}\n")
        self.paths[3].write_text(
            "core.demo\tcore\tdemo\t1.0.0\t1.1.0\tpinned-sha256\told -> sha256:"
            + "b" * 64
            + "\n"
        )

    def test_flow_yaml_comments_and_unselected_fields_are_preserved(self):
        before_external = self.paths[2].stat().st_mtime_ns
        module.apply(*self.paths)
        self.assertEqual(
            self.paths[0].read_text(),
            '# keep this comment\ncore: {demo: "1.1.0", other: "2.0.0"} # keep order\n',
        )
        self.assertIn("b" * 64, self.paths[1].read_text())
        self.assertEqual(self.paths[2].stat().st_mtime_ns, before_external)

    def test_invalid_checksum_and_stale_plan_never_change_destinations(self):
        original = [path.read_bytes() for path in self.paths[:3]]
        for invalid in (
            self.paths[3].read_text().replace("b" * 64, "invalid"),
            self.paths[3].read_text().replace("\t1.0.0\t", "\t0.9.0\t"),
        ):
            self.paths[3].write_text(invalid)
            with self.assertRaises(ValueError):
                module.apply(*self.paths)
            self.assertEqual([path.read_bytes() for path in self.paths[:3]], original)

    def test_duplicate_targets_fail_before_writing(self):
        original = self.paths[0].read_text()
        self.paths[3].write_text(self.paths[3].read_text() * 2)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            module.apply(*self.paths)
        self.assertEqual(self.paths[0].read_text(), original)


if __name__ == "__main__":
    unittest.main()
