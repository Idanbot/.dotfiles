#!/usr/bin/env python3
"""Offline launcher/theme call-site regressions with synthetic homes and payloads."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class FileAssetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="asset home ")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.state = self.home / "state"
        self.calls = self.home / "downloads"
        self.app = self.home / ".local/kitty.app"
        self.app_sources = self.app / "share/applications"
        self.app_sources.mkdir(parents=True)
        for name in ("kitty.desktop", "kitty-open.desktop"):
            (self.app_sources / name).write_text(
                "[Desktop Entry]\nName=Kitty fixture\nExec=kitty --single-instance %U\nTryExec=kitty\nIcon=kitty\n"
            )
        self.env = {
            **os.environ, "HOME": str(self.home), "DOTFILES_SOURCE_DIR": str(ROOT),
            "DOTFILES_STATE_DIR": str(self.state), "DOTFILES_DOWNLOAD_CACHE": "0",
            "TARGET": str(self.app), "VERSION": "1.0.0", "NATIVE": "1",
            "CALLS": str(self.calls), "THEME_DATA": "verified theme fixture", "NO_COLOR": "1",
        }
        self.btop = self.home / ".config/btop/themes/catppuccin_mocha.theme"
        self.kitty_theme = self.home / ".config/kitty/themes/catppuccin_mocha.conf"
        self.launcher = self.home / ".local/share/applications/kitty.desktop"

    def shell(self, body, **env):
        return subprocess.run(
            ["bash", "-c", 'set -euo pipefail; source "$DOTFILES_SOURCE_DIR/scripts/lib.sh";\n' + body],
            env={**self.env, **env}, capture_output=True, text=True, timeout=15,
        )

    def receipts(self):
        # Scoped recovery may reorder TSV rows while preserving every record.
        return {str(path.relative_to(self.state)):
                b"".join(sorted(path.read_bytes().splitlines(keepends=True)))
                if path.name == "installed.tsv" else path.read_bytes()
                for path in self.state.rglob("*") if path.is_file() and not path.name.endswith(".lock")}

    def launchers(self, prefix="", **env):
        installer = (ROOT / "scripts/install-kitty.sh").read_text()
        start = installer.index("for desktop_file in ")
        body = installer[start:installer.index("\ndone", start) + len("\ndone")]
        return self.shell(prefix + "\n" + body, **env)

    def themes(self, prefix="", **env):
        section = (ROOT / ".chezmoiscripts/run_once_13-apply-catppuccin-theme.sh.tmpl").read_text()
        body = section[section.index('log_step "Applying'):]
        payload = (env.get("THEME_DATA", self.env["THEME_DATA"]) + "\n").encode()
        digest = hashlib.sha256(payload).hexdigest()
        body = re.sub(r"^([ \t]*(?:BTOP|KITTY)_SHA)=.*$", rf"\1={digest}", body, flags=re.M)
        transport = '''
is_native() { [[ "$NATIVE" == 1 ]]; }
download() {
  printf '%s\\n' "$1" >>"$CALLS"
  [[ "${FAIL_DOWNLOAD:-0}" != 1 ]] || return 7
  printf '%s\\n' "$THEME_DATA" >"$2"
  [[ "${CORRUPT_DOWNLOAD:-0}" != 1 ]] || printf 'corrupt\\n' >>"$2"
}
'''
        return self.shell(transport + prefix + "\n" + body, **env)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def seed(self, path, content="local customization\n"):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def test_launchers_preserve_unowned_customizations(self):
        self.seed(self.launcher, "[Desktop Entry]\nExec=kitty --config custom.conf\n")
        before = self.launcher.read_bytes()
        self.assert_ok(self.launchers())
        self.assertEqual(self.launcher.read_bytes(), before)
        self.assertNotIn(str(self.launcher), (self.state / "installed.tsv").read_text())

    def test_launchers_reject_symlinks_and_redirected_parents(self):
        external = self.home / "external"
        external.mkdir()
        marker = external / "keep"
        marker.write_text("preserve\n")
        self.launcher.parent.mkdir(parents=True)
        self.launcher.symlink_to(marker)
        self.assert_ok(self.launchers())
        self.assertTrue(self.launcher.is_symlink())
        self.assertEqual(marker.read_text(), "preserve\n")
        self.launcher.unlink()
        (self.launcher.parent / "kitty-open.desktop").unlink(missing_ok=True)
        self.launcher.parent.rmdir()
        self.launcher.parent.symlink_to(external, target_is_directory=True)
        self.assert_ok(self.launchers())
        self.assertEqual(sorted(p.name for p in external.iterdir()), ["keep"])

    def test_launchers_publish_update_and_converge(self):
        self.assert_ok(self.launchers())
        self.assert_ok(self.shell('target_is_owned "$HOME/.local/share/applications/kitty.desktop"'))
        content = self.launcher.read_text()
        self.assertIn(str(self.app / "bin/kitty"), content)
        self.assertIn("TryExec = " + str(self.app / "bin/kitty"), content)
        self.assertIn("--single-instance %U", content)
        self.assertIn(str(self.app / "share/icons/hicolor/256x256/apps/kitty.png"), content)
        self.assertEqual(self.launcher.stat().st_mode & 0o777, 0o644)
        before = self.launcher.read_bytes(), self.launcher.stat().st_mtime_ns, self.receipts()
        self.assert_ok(self.launchers())
        self.assertEqual((self.launcher.read_bytes(), self.launcher.stat().st_mtime_ns, self.receipts()), before)
        self.seed(self.app_sources / "kitty.desktop", "[Desktop Entry]\nExec=kitty --new-flag\nIcon=kitty\n")
        self.assert_ok(self.launchers(VERSION="2.0.0"))
        self.assertIn("--new-flag", self.launcher.read_text())

    def test_launcher_receipt_failure_rolls_back(self):
        self.assert_ok(self.launchers())
        before = self.launcher.read_bytes(), self.receipts()
        self.seed(self.app_sources / "kitty.desktop", "[Desktop Entry]\nExec=kitty --changed\n")
        result = self.launchers("record_install() { return 9; }", VERSION="2.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.launcher.read_bytes(), self.receipts()), before)

    def test_themes_preserve_external_and_modified_files_without_download(self):
        self.seed(self.btop)
        self.seed(self.kitty_theme)
        self.assert_ok(self.themes())
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.btop.read_text(), "local customization\n")
        self.assertEqual(self.kitty_theme.read_text(), "local customization\n")
        self.assertNotIn(str(self.btop), (self.state / "installed.tsv").read_text())
        self.assert_ok(self.shell('record_install btop-theme old fixture "$HOME/.config/btop/themes/catppuccin_mocha.theme"'))
        self.btop.write_text("modified after ownership\n")
        before = self.receipts()
        self.assert_ok(self.themes())
        self.assertEqual(self.btop.read_text(), "modified after ownership\n")
        self.assertEqual(self.receipts(), before)
        self.assertFalse(self.calls.exists())

    def test_themes_publish_verified_updates_and_converge(self):
        self.assert_ok(self.themes())
        self.assertEqual(self.btop.read_text(), "verified theme fixture\n")
        self.assertEqual(self.kitty_theme.read_text(), "verified theme fixture\n")
        before = self.btop.stat().st_mtime_ns, self.kitty_theme.stat().st_mtime_ns, self.receipts(), self.calls.read_bytes()
        self.assert_ok(self.themes())
        self.assertEqual((self.btop.stat().st_mtime_ns, self.kitty_theme.stat().st_mtime_ns, self.receipts(), self.calls.read_bytes()), before)
        self.assert_ok(self.themes(THEME_DATA="updated verified fixture"))
        self.assertEqual(self.btop.read_text(), "updated verified fixture\n")

    def test_theme_failures_leave_owned_files_and_receipts_intact(self):
        self.assert_ok(self.themes())
        before = self.btop.read_bytes(), self.kitty_theme.read_bytes(), self.receipts()
        for failure in ("download", "checksum", "receipt"):
            with self.subTest(failure=failure):
                result = self.themes(
                    "record_install() { return 9; }" if failure == "receipt" else "",
                    THEME_DATA="new candidate", FAIL_DOWNLOAD=str(int(failure == "download")),
                    CORRUPT_DOWNLOAD=str(int(failure == "checksum")),
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.btop.read_bytes(), self.kitty_theme.read_bytes(), self.receipts()), before)

    def test_themes_preserve_nonregular_and_redirected_destinations(self):
        external = self.home / "external-themes"
        external.mkdir()
        self.btop.parent.parent.mkdir(parents=True)
        self.btop.parent.symlink_to(external, target_is_directory=True)
        self.kitty_theme.parent.mkdir(parents=True)
        os.mkfifo(self.kitty_theme)
        self.assert_ok(self.themes())
        self.assertFalse(self.calls.exists())
        self.assertEqual(list(external.iterdir()), [])

    def test_wsl_theme_branch_omits_kitty(self):
        self.assert_ok(self.themes(NATIVE="0"))
        self.assertTrue(self.btop.is_file())
        self.assertFalse(self.kitty_theme.exists())
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_legacy_theme_without_stamp_is_not_adopted(self):
        self.seed(self.btop)
        self.seed(self.home / ".config/lazygit/config.yml", "user: preserved\n")
        self.assert_ok(self.shell('record_install btop-theme old fixture "$HOME/.config/btop/themes/catppuccin_mocha.theme"; '
                                  'rm "$(ownership_stamp "$HOME/.config/btop/themes/catppuccin_mocha.theme")"'))
        before = self.receipts()
        self.assert_ok(self.themes(NATIVE="0"))
        self.assertEqual(self.btop.read_text(), "local customization\n")
        self.assertEqual(self.receipts(), before)
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
