#!/usr/bin/env bash
# Failed integrity or ineligible releases must never become accepted updates.
set -euo pipefail
DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
exec /usr/bin/python3 - "$DOTFILES_DIR" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import quote

import yaml

ROOT = Path(sys.argv.pop(1)).resolve()
TRACKED = ("packages.yaml", "packages.meta.yaml", "packages.lock", "README.md",
           "docs/tool-inventory.md", ".chezmoiexternal.yaml")
SHA = "a" * 64


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.tmp = Path(self.directory.name)
        self.source = self.tmp / "source"
        shutil.copytree(ROOT / "scripts", self.source / "scripts",
                        ignore=shutil.ignore_patterns("__pycache__"))
        for name in TRACKED:
            target = self.source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        self.pins = yaml.safe_load((self.source / "packages.yaml").read_text())
        self.meta = yaml.safe_load((self.source / "packages.meta.yaml").read_text())
        self.responses = {}
        self.calls = self.tmp / "calls"
        binary = self.tmp / "bin"
        binary.mkdir()
        curl = binary / "curl"
        curl.write_text('''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
url = args[-1]
with open(os.environ["MOCK_CALLS"], "a") as log:
    log.write(url + "\\n")
item = json.loads(Path(os.environ["MOCK_RESPONSES"]).read_text()).get(url, {})
body = item.get("body", "")
body = body if isinstance(body, str) else json.dumps(body)
if "-o" in args:
    Path(args[args.index("-o") + 1]).write_text(body)
else:
    sys.stdout.write(body)
sys.exit(item.get("status", 22))
''')
        curl.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{binary}:{os.environ['PATH']}",
                    "HOME": str(self.tmp), "DOTFILES_SOURCE_DIR": str(self.source),
                    "DOTFILES_STATE_DIR": str(self.tmp / "state"),
                    "GITHUB_TOKEN": "fixture-token", "GH_TOKEN": "fixture-token",
                    "MOCK_CALLS": str(self.calls),
                    "MOCK_RESPONSES": str(self.tmp / "responses.json")}
        for name in ("DOTFILES_UPGRADE_FIXTURE", "DOTFILES_PACKAGES_FILE", "DOTFILES_META_FILE",
                     "DOTFILES_PACKAGES_META_FILE", "DOTFILES_EXTERNALS_FILE", "DOTFILES_DIR"):
            self.env.pop(name, None)

    def respond(self, url, body, status=0):
        self.responses[url] = {"body": body, "status": status}
        return url

    def run_updater(self, *args):
        Path(self.env["MOCK_RESPONSES"]).write_text(json.dumps(self.responses))
        result = subprocess.run(
            ["bash", str(self.source / "scripts/update-packages.sh"), *args,
             "--report", str(self.tmp / "report.md")],
            env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=60,
        )
        self.output = result.stdout
        self.report = (self.tmp / "report.md").read_text()
        return result.returncode

    def snapshot(self):
        return {name: (self.source / name).read_bytes() for name in TRACKED}

    def reject(self, target, unresolved=True):
        before = self.snapshot()
        try:
            status = self.run_updater("--apply", target)
            changed = [name for name, body in before.items()
                       if (self.source / name).read_bytes() != body]
            self.assertEqual(changed, [], f"Rejected {target} mutated outputs:\n{self.output}")
            self.assertNotEqual(status, 0, self.output)
            if unresolved:
                self.assertIn("unresolved", self.report)
                self.assertIn("selected updates contain unresolved checksums", self.output)
        finally:
            for name, body in before.items():
                (self.source / name).write_bytes(body)

    def fail_transfers(self, target, urls, unresolved=True):
        for url in urls:
            original = self.responses[url].copy()
            for status, body in ((22, ""), (18, original["body"])):
                with self.subTest(target=target, url=url, status=status):
                    self.responses[url] = {"body": body, "status": status}
                    self.reject(target, unresolved=unresolved)
            self.responses[url] = original

    def test_github_fallback_and_release_metadata(self):
        assets = []
        urls = []
        for arch in ("x86_64", "aarch64"):
            asset = f"eza_{arch}-unknown-linux-gnu.tar.gz"
            url = self.respond(f"https://fixtures.test/{asset}", "partial archive")
            assets.append({"name": asset, "browser_download_url": url})
            urls.append(url)
        release = self.respond("https://api.github.com/repos/eza-community/eza/releases/tags/v99.0.0",
                               {"assets": assets})
        self.fail_transfers("core.eza@99.0.0", urls)
        for asset in assets:
            asset["digest"] = "sha256:" + SHA
        self.responses[release]["body"] = {"assets": assets}
        self.fail_transfers("core.eza@99.0.0", [release])

    def test_external_archives(self):
        for ident, repo in (("core.fzf", "junegunn/fzf"),
                            ("ai_tools.ponytail", "DietrichGebert/ponytail")):
            group, key = ident.split(".")
            old = self.respond(f"https://codeload.github.com/{repo}/tar.gz/refs/tags/v{self.pins[group][key]}",
                               "complete old archive")
            new = self.respond(f"https://codeload.github.com/{repo}/tar.gz/refs/tags/v99.0.0",
                               "partial new archive")
            self.fail_transfers(ident + "@99.0.0", [old, new] if key == "fzf" else [new])

    def test_pypi_integrity(self):
        package = "tmuxp"
        current = self.pins["terminal"][package]
        base = f"https://pypi.org/pypi/{package}"
        self.respond(base + "/json", {"info": {"version": "99.0.0"},
                                     "releases": {current: [{}], "99.0.0": [{}]}})
        urls = [self.respond(f"{base}/{value}/json", {"urls": [{"digests": {"sha256": SHA}}]})
                for value in (current, "99.0.0")]
        self.fail_transfers("terminal.tmuxp@99.0.0", urls)

    def test_mutable_installer_transfer_failure(self):
        for key in ("codex_cli", "antigravity_cli"):
            url = self.respond(self.meta["ai_tools"][key]["url"], "partial installer")
            self.fail_transfers("ai_tools." + key, [url], unresolved=False)

    def node_checksums(self, value):
        return self.respond(f"https://nodejs.org/dist/v{value}/SHASUMS256.txt",
                            "".join(f"{SHA}  node-v{value}-linux-{arch}.tar.xz\n"
                                    for arch in ("x64", "arm64")))

    def test_direct_checksums(self):
        for ident, proposed in (("languages.node", "26.99.9"), ("languages.go", "1.27.99"),
                                ("languages.java", "25.99.0+1"), ("cloud.kubectl", "1.99.0"),
                                ("cloud.helm", "4.99.0"), ("cloud.terraform", "1.99.0"),
                                ("cloud.aws_cli", "2.99.0")):
            group, key = ident.split(".")
            urls = []
            for value in (self.pins[group][key], proposed):
                if key == "node":
                    url = self.node_checksums(value)
                    if value == proposed:
                        urls.append(url)
                elif key == "go":
                    files = [{"filename": f"go{v}.linux-{arch}.tar.gz", "sha256": SHA}
                             for v in (self.pins[group][key], proposed) for arch in ("amd64", "arm64")]
                    url = self.respond("https://go.dev/dl/?mode=json&include=all",
                                       [{"version": "go" + proposed, "stable": True, "files": files}])
                    urls = [url]
                elif key == "java":
                    for arch in ("x64", "aarch64"):
                        url = self.respond(
                            f"https://api.adoptium.net/v3/assets/feature_releases/{value.split('.')[0]}/ga?architecture={arch}&heap_size=normal&image_type=jdk&jvm_impl=hotspot&os=linux&vendor=eclipse",
                            [{"release_name": "jdk-" + v, "binaries": [{"package": {"checksum": SHA}}]}
                             for v in (self.pins[group][key], proposed)])
                        if value == proposed:
                            urls.append(url)
                elif key == "terraform":
                    url = self.respond(
                        f"https://releases.hashicorp.com/terraform/{value}/terraform_{value}_SHA256SUMS",
                        "".join(f"{SHA}  terraform_{value}_linux_{arch}.zip\n" for arch in ("amd64", "arm64")))
                    if value == proposed:
                        urls.append(url)
                else:
                    for arch in ("amd64", "arm64"):
                        if key == "kubectl":
                            url, body = f"https://dl.k8s.io/release/v{value}/bin/linux/{arch}/kubectl.sha256", SHA
                        elif key == "helm":
                            url = f"https://get.helm.sh/helm-v{value}-linux-{arch}.tar.gz.sha256sum"
                            body = f"{SHA}  helm-v{value}-linux-{arch}.tar.gz\n"
                        else:
                            vendor_arch = "x86_64" if arch == "amd64" else "aarch64"
                            url = f"https://awscli.amazonaws.com/awscli-exe-linux-{vendor_arch}-{value}.zip"
                            body = "partial AWS archive"
                        self.respond(url, body)
                        if value == proposed:
                            urls.append(url)
            self.fail_transfers(ident + "@" + proposed, urls)

    def npm(self, ident, choices, latest):
        group, key = ident.split(".")
        package = self.meta[group][key]["package"]
        base = "https://registry.npmjs.org/" + quote(package, safe="@")
        versions = {value: {"version": value, "engines": {"node": engine},
                            "dist": {"integrity": "sha512-fixture-" + value}}
                    for value, engine in choices.items()}
        self.respond(base, {"dist-tags": {"latest": latest}, "versions": versions})
        self.respond(base + "/latest", versions[latest])
        for value, item in versions.items():
            self.respond(base + "/" + value, item)

    def candidate_fixture(self):
        self.pins["languages"].update(node="26.11.1", npm="12.0.0", typescript="7.0.0")
        self.pins["ai_tools"].update(opencode="1.0.0", pix_optimizer="1.0.0")
        (self.source / "packages.yaml").write_text(yaml.safe_dump(self.pins, sort_keys=False))
        self.respond("https://nodejs.org/dist/index.json",
                     [{"version": "v" + value} for value in ("27.0.0", "26.12.0", "26.11.2")])
        for value in ("26.11.1", "26.11.2", "26.12.0", "27.0.0"):
            self.node_checksums(value)
        for ident in ("ai_tools.opencode", "ai_tools.pix_optimizer"):
            self.npm(ident, {"1.0.0": ">=26", "1.1.0": ">=26", "2.0.0": ">=26.12",
                             "3.0.0": ">=27", "4.0.0": ">=26"}, "3.0.0")
        self.npm("languages.npm", {"12.0.0": ">=26", "12.0.1": ">=26",
                                   "13.0.0": ">=26.12", "14.0.0": ">=27"}, "14.0.0")
        self.npm("languages.typescript", {"7.0.0": ">=26", "7.1.0": ">=26.12", "8.0.0": ">=26"}, "8.0.0")

    def assert_pins(self, **expected):
        actual = yaml.safe_load((self.source / "packages.yaml").read_text())
        for ident, value in expected.items():
            group, key = ident.split(".")
            self.assertEqual(actual[group][key], value, self.output)

    def test_selected_npm_uses_pinned_node(self):
        self.candidate_fixture()
        self.assertEqual(self.run_updater("--apply", "ai_tools.opencode", "ai_tools.pix_optimizer", "languages.npm"), 0,
                         self.output)
        self.assert_pins(**{"languages.node": "26.11.1", "languages.npm": "12.0.1",
                            "ai_tools.opencode": "1.1.0", "ai_tools.pix_optimizer": "1.1.0"})
        self.assertNotIn("https://nodejs.org/dist/index.json", self.calls.read_text())
        self.assertNotIn("/latest", self.calls.read_text())

    def test_apply_all_uses_proposed_node_and_release_lines(self):
        self.candidate_fixture()
        self.assertEqual(self.run_updater("--apply-all"), 0, self.output)
        self.assert_pins(**{"languages.node": "26.12.0", "languages.npm": "13.0.0",
                            "languages.typescript": "7.1.0", "ai_tools.opencode": "2.0.0"})

    def test_node_checksum_failure_blocks_the_entire_grouped_apply(self):
        self.candidate_fixture()
        self.responses["https://nodejs.org/dist/v26.12.0/SHASUMS256.txt"]["status"] = 18
        before = self.snapshot()
        self.assertNotEqual(self.run_updater("--apply-all"), 0, self.output)
        self.assertIn("selected updates contain unresolved checksums", self.output)
        self.assertEqual(self.snapshot(), before)

    def test_explicit_node_governs_every_npm_candidate(self):
        for node, expected in (("26.11.2", "1.1.0"), ("27.0.0", "3.0.0")):
            with self.subTest(node=node):
                self.candidate_fixture()
                self.assertEqual(self.run_updater("--apply", "ai_tools.opencode", "languages.node@" + node), 0,
                                 self.output)
                self.assert_pins(**{"languages.node": node, "ai_tools.opencode": expected})

    def test_explicit_npm_cannot_bypass_eligibility(self):
        self.candidate_fixture()
        for target in ("ai_tools.opencode@3.0.0", "ai_tools.opencode@4.0.0",
                       "ai_tools.opencode@3.0.0-rc.1", "ai_tools.opencode@9.0.0"):
            with self.subTest(target=target):
                self.reject(target, unresolved=False)

    def test_explicit_compatible_major_remains_available(self):
        self.candidate_fixture()
        self.assertEqual(self.run_updater("--apply", "languages.typescript@8.0.0"), 0, self.output)
        self.assert_pins(**{"languages.typescript": "8.0.0", "languages.node": "26.11.1"})

    def test_incompatible_only_updates_are_held(self):
        self.candidate_fixture()
        self.npm("ai_tools.opencode", {"1.0.0": ">=26", "3.0.0": ">=27"}, "3.0.0")
        self.reject("ai_tools.opencode", unresolved=False)


unittest.main()
PY
