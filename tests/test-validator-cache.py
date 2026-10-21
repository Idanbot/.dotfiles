#!/usr/bin/env python3
"""Cache freshness, invalidation, corruption, and fallback without a Docker socket."""

from datetime import datetime, timezone
import hashlib
import importlib.util
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
    "cache_policy", ROOT / "scripts/ci/cache-policy.py"
)
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class KeyTests(unittest.TestCase):
    def test_input_and_platform_drift_invalidates_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in POLICY.VALIDATOR_INPUTS:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name)
            date = datetime(2026, 10, 19, tzinfo=timezone.utc)
            original = POLICY.cache_key(root, "Linux-X64", date)
            self.assertEqual(original, POLICY.cache_key(root, "Linux-X64", date))
            self.assertNotEqual(original, POLICY.cache_key(root, "Linux-ARM64", date))
            for name in POLICY.VALIDATOR_INPUTS:
                with self.subTest(name=name):
                    path = root / name
                    previous = path.read_text()
                    path.write_text(previous + "changed")
                    self.assertNotEqual(
                        original, POLICY.cache_key(root, "Linux-X64", date)
                    )
                    path.write_text(previous)
            (root / "README.md").write_text("unrelated edit")
            self.assertEqual(original, POLICY.cache_key(root, "Linux-X64", date))
            (root / POLICY.VALIDATOR_INPUTS[0]).unlink()
            with self.assertRaises(FileNotFoundError):
                POLICY.cache_key(root, "Linux-X64", date)

    def test_weekly_refresh_including_iso_year_boundary(self):
        date = datetime(2026, 10, 19, tzinfo=timezone.utc)
        key, period = POLICY.cache_key(ROOT, "Linux-X64", date)
        self.assertEqual(period, "2026-W43")
        self.assertEqual(
            key, POLICY.cache_key(ROOT, "Linux-X64", date.replace(day=25))[0]
        )
        self.assertNotEqual(
            key, POLICY.cache_key(ROOT, "Linux-X64", date.replace(day=26))[0]
        )
        boundary = datetime(2027, 1, 1, tzinfo=timezone.utc)
        self.assertEqual("2026-W53", POLICY.cache_key(ROOT, "Linux-X64", boundary)[1])
        with self.assertRaises(ValueError):
            POLICY.cache_key(ROOT, "Linux/../../", date)


@unittest.skipUnless(shutil.which("zstd"), "zstd required")
class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.cache = self.root / "cache"
        self.calls = self.root / "calls"
        docker = self.bin / "docker"
        docker.write_text("""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"$MOCK_CALLS"
case "$1" in
  build) [[ "${BUILD_FAIL:-false}" != true ]] ;;
  save) printf 'valid-image-tar' ;;
  load) cat >/dev/null; [[ "${LOAD_FAIL:-false}" != true ]] ;;
  image)
    if [[ "$*" == *'.Size'* ]]; then echo 123456; else printf 'sha256:%064d\\n' "${IMAGE_NUMBER:-1}"; fi
    ;;
  *) exit 9 ;;
esac
""")
        docker.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "MOCK_CALLS": str(self.calls),
            "GITHUB_OUTPUT": str(self.root / "outputs"),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary"),
        }

    def run_cache(
        self,
        operation="ensure",
        period="2026-W43",
        identity="reviewed-inputs",
        **overrides,
    ):
        return subprocess.run(
            [
                "bash",
                str(ROOT / "scripts/ci/validator-image.sh"),
                operation,
                str(self.cache),
                "dotfiles-ci-tests",
                period,
                identity,
            ],
            env={**self.env, **overrides},
            capture_output=True,
            text=True,
        )

    def test_cold_warm_and_corrupt_cache(self):
        self.assertEqual(0, self.run_cache().returncode)
        self.assertIn("build --pull", self.calls.read_text())
        self.calls.write_text("")
        self.assertEqual(0, self.run_cache().returncode)
        self.assertNotIn("build", self.calls.read_text())
        self.assertIn("hit=true", (self.root / "outputs").read_text())
        (self.cache / "test-image.tar.zst").write_bytes(b"corrupt")
        self.calls.write_text("")
        self.assertNotEqual(0, self.run_cache("load").returncode)
        self.assertFalse(self.calls.read_text())
        (self.cache / "test-image.tar.zst.sha256").write_text(
            hashlib.sha256(b"corrupt").hexdigest()
        )
        self.assertNotEqual(0, self.run_cache("load").returncode)
        self.assertFalse(self.calls.read_text())
        self.assertEqual(0, self.run_cache().returncode)
        self.assertIn("build --pull", self.calls.read_text())

    def test_load_failure_rebuilds_but_artifact_load_fails(self):
        self.assertEqual(0, self.run_cache().returncode)
        self.calls.write_text("")
        self.assertNotEqual(0, self.run_cache("load", LOAD_FAIL="true").returncode)
        self.assertNotIn("build", self.calls.read_text())
        self.assertEqual(0, self.run_cache(LOAD_FAIL="true").returncode)
        self.assertIn("build --pull", self.calls.read_text())

    def test_wrong_image_id_and_missing_digest_cannot_hit(self):
        self.assertEqual(0, self.run_cache().returncode)
        self.assertNotEqual(0, self.run_cache("load", IMAGE_NUMBER="2").returncode)
        (self.cache / "test-image.tar.zst.sha256").unlink()
        self.calls.write_text("")
        self.assertEqual(0, self.run_cache().returncode)
        self.assertIn("build --pull", self.calls.read_text())

    def test_rebuild_failure_is_fatal(self):
        self.assertNotEqual(0, self.run_cache(BUILD_FAIL="true").returncode)
        self.assertFalse((self.cache / "test-image.tar.zst").exists())

    def test_stale_identity_or_refresh_period_rebuilds(self):
        self.assertEqual(0, self.run_cache().returncode)
        self.calls.write_text("")
        self.assertEqual(
            0, self.run_cache(identity="changed-reviewed-inputs").returncode
        )
        self.assertIn("build --pull", self.calls.read_text())
        self.calls.write_text("")
        self.assertEqual(
            0,
            self.run_cache(
                period="2026-W44", identity="changed-reviewed-inputs"
            ).returncode,
        )
        self.assertIn("VALIDATOR_REFRESH=2026-W44", self.calls.read_text())


if __name__ == "__main__":
    unittest.main()
