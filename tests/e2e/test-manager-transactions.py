#!/usr/bin/env python3
"""Exercise installed npm/uv against tiny local packages, never user state."""

import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import threading
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = "dotfiles-manager-fixture"
BINARY = "dotfiles-fixture"


class NativeManagerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native manager home ")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.state = self.home / "state"
        self.bins = self.home / ".local/bin"
        self.bins.mkdir(parents=True)
        self.environment = {
            **os.environ,
            "HOME": str(self.home),
            "DOTFILES_SOURCE_DIR": str(ROOT),
            "DOTFILES_STATE_DIR": str(self.state),
            "DOTFILES_VERSION_PLAN": "",
            "UV_TOOL_DIR": str(self.home / "uv-tools"),
            "UV_TOOL_BIN_DIR": str(self.bins),
            "UV_CACHE_DIR": str(self.home / "uv-cache"),
            "UV_NO_INDEX": "1",
            "UV_PYTHON_DOWNLOADS": "never",
            "UV_OFFLINE": "1",
            "UV_NO_CONFIG": "1",
            "DOTFILES_NPM_PREFIX": str(self.home / "npm-prefix"),
            "npm_config_cache": str(self.home / "npm-cache"),
            "npm_config_userconfig": "/dev/null",
            "npm_config_ignore_scripts": "true",
            "PATH": str(self.bins) + ":" + os.environ["PATH"],
            "NO_COLOR": "1",
        }
        for variable in (
            "DOTFILES_EVENT_LOG",
            "DOTFILES_MANAGER_LOG",
            "DOTFILES_REPLACE_BINARIES",
        ):
            self.environment.pop(variable, None)

    def shell(self, command, check=True):
        result = subprocess.run(
            [
                "bash",
                "-c",
                'set -euo pipefail; source "$DOTFILES_SOURCE_DIR/scripts/lib.sh"; '
                'source "$DOTFILES_SOURCE_DIR/scripts/install-uv-tool.sh"; ' + command,
            ],
            env=self.environment,
            text=True,
            capture_output=True,
            check=False,
            timeout=45,
        )
        if check and result.returncode:
            self.fail(f"{command}\n{result.stdout}{result.stderr}")
        return result

    def receipts(self):
        return {
            str(path.relative_to(self.state)): (
                b"\n".join(sorted(path.read_bytes().splitlines()))
                if path.name == "installed.tsv"
                else path.read_bytes()
            )
            for path in self.state.rglob("*")
            if path.is_file() and not path.name.endswith(".lock")
        }

    def version(self):
        return subprocess.check_output(
            [str(self.bins / BINARY), "--version"], env=self.environment, text=True
        ).strip()

    def test_uv_native_upgrade_rollback_and_idempotency(self):
        wheels = self.home / "wheels"
        wheels.mkdir()
        self.environment["UV_FIND_LINKS"] = str(wheels)
        for version in ("1.0.0", "2.0.0", "3.0.0", "2026.8.19"):
            distribution = "dotfiles_manager_fixture-" + version + ".dist-info/"
            with zipfile.ZipFile(
                wheels / f"dotfiles_manager_fixture-{version}-py3-none-any.whl", "w"
            ) as wheel:
                body = (
                    "raise SystemExit(37)"
                    if version == "3.0.0"
                    else f"print({version!r})"
                )
                wheel.writestr("manager_fixture.py", f"def main():\n    {body}\n")
                wheel.writestr(
                    distribution + "METADATA",
                    f"Metadata-Version: 2.1\nName: {PACKAGE}\nVersion: {version}\n",
                )
                wheel.writestr(
                    distribution + "WHEEL",
                    "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
                )
                wheel.writestr(
                    distribution + "entry_points.txt",
                    f"[console_scripts]\n{BINARY} = manager_fixture:main\n",
                )
                wheel.writestr(distribution + "RECORD", "")
        self.shell(f"install_uv_tool {BINARY} {PACKAGE} 1.0.0 /usr/bin/python3")
        before = self.receipts()
        failed = self.shell(
            f"install_uv_tool {BINARY} {PACKAGE} 3.0.0 /usr/bin/python3", check=False
        )
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        self.assertEqual(self.version(), "1.0.0")
        self.assertEqual(self.receipts(), before)
        self.shell(f"install_uv_tool {BINARY} {PACKAGE} 2.0.0 /usr/bin/python3")
        self.assertEqual(self.version(), "2.0.0")
        before = self.receipts()
        self.shell(f"install_uv_tool {BINARY} {PACKAGE} 2.0.0 /usr/bin/python3")
        self.assertEqual(self.receipts(), before)
        self.shell(f"install_uv_tool {BINARY} {PACKAGE} 2026.08.19 /usr/bin/python3")
        self.assertEqual(self.version(), "2026.8.19")
        before = self.receipts()
        self.shell(f"install_uv_tool {BINARY} {PACKAGE} 2026.08.19 /usr/bin/python3")
        self.assertEqual(self.receipts(), before)
        self.shell(f'bash "$DOTFILES_SOURCE_DIR/scripts/uninstall-tool.sh" {BINARY}')
        self.assertFalse((self.home / "uv-tools" / PACKAGE).exists())
        self.assertFalse((self.bins / BINARY).is_symlink())

    def test_npm_native_upgrade_ledger_rollback_and_idempotency(self):
        packages = {}
        for version in ("1.0.0", "2.0.0"):
            stream = io.BytesIO()
            contents = {
                "package.json": json.dumps(
                    {"name": PACKAGE, "version": version, "bin": {BINARY: "cli.js"}}
                ),
                "cli.js": f"#!/usr/bin/env node\nconsole.log({version!r});\n",
            }
            with tarfile.open(fileobj=stream, mode="w:gz") as archive:
                for name, value in contents.items():
                    info = tarfile.TarInfo("package/" + name)
                    data = value.encode()
                    info.size, info.mode = (
                        len(data),
                        0o755 if name.endswith(".js") else 0o644,
                    )
                    archive.addfile(info, io.BytesIO(data))
            packages[version] = stream.getvalue()

        class Registry(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                if self.path == "/" + PACKAGE:
                    versions = {
                        version: {
                            "name": PACKAGE,
                            "version": version,
                            "bin": {BINARY: "cli.js"},
                            "dist": {
                                "tarball": f"http://127.0.0.1:{self.server.server_port}/{version}.tgz",
                                "integrity": "sha512-"
                                + base64.b64encode(
                                    hashlib.sha512(data).digest()
                                ).decode(),
                            },
                        }
                        for version, data in packages.items()
                    }
                    body = json.dumps(
                        {
                            "name": PACKAGE,
                            "dist-tags": {"latest": "2.0.0"},
                            "versions": versions,
                        }
                    ).encode()
                else:
                    body = packages.get(
                        self.path.removeprefix("/").removesuffix(".tgz")
                    )
                if body is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Registry)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.environment["npm_config_registry"] = (
            f"http://127.0.0.1:{server.server_port}"
        )
        self.shell(f"npm_install_global {PACKAGE} 1.0.0 {BINARY}")
        before = self.receipts()
        failed = self.shell(
            f"record_install() {{ return 1; }}; npm_install_global {PACKAGE} 2.0.0 {BINARY}",
            check=False,
        )
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        self.assertEqual(self.version(), "1.0.0")
        self.assertEqual(self.receipts(), before)
        self.shell(f"npm_install_global {PACKAGE} 2.0.0 {BINARY}")
        self.assertEqual(self.version(), "2.0.0")
        before = self.receipts()
        self.shell(f"npm_install_global {PACKAGE} 2.0.0 {BINARY}")
        self.assertEqual(self.receipts(), before)
        self.shell(f'bash "$DOTFILES_SOURCE_DIR/scripts/uninstall-tool.sh" {BINARY}')
        self.assertFalse((self.home / "npm-prefix/lib/node_modules" / PACKAGE).exists())
        self.assertFalse((self.bins / BINARY).is_symlink())


if __name__ == "__main__":
    if not Path("/.dockerenv").exists() or not all(
        shutil.which(tool) for tool in ("uv", "node", "npm")
    ):
        raise SystemExit(
            "Run in the languages E2E Docker image with npm and uv installed"
        )
    unittest.main()
