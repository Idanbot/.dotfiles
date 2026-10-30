#!/usr/bin/env python3
"""Disposable real-OpenSSH tests; all Access/authentication data is synthetic."""

import json
import os
from pathlib import Path
import pty
import secrets
import select
import signal
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r"""#!/usr/bin/python3
import json, os, select, socket, subprocess, sys, time
from pathlib import Path
mode = sys.argv[2]
with open(os.environ["CF_CALLS"], "a") as stream:
    stream.write(json.dumps({"mode": mode}) + "\n")
cache = Path(os.environ["CF_CACHE"])
if mode == "token":
    if cache.exists() and os.environ.get("CF_EXPIRED") != "1": print("SYNTHETIC_TOKEN_STDOUT")
    sys.exit(0)
if mode == "login":
    if not cache.exists() or os.environ.get("CF_EXPIRED") == "1":
        print("Access approval fixture", file=sys.stderr)
        time.sleep(float(os.environ.get("CF_LOGIN_DELAY", "0")))
        if os.environ.get("CF_DENY") == "1": sys.exit(7)
        cache.touch()
    print("SYNTHETIC_TOKEN_STDOUT")
    sys.exit(0)
if mode == "ssh":
    if os.environ.get("CF_ORIGIN_DOWN") == "1": sys.exit(8)
    if os.environ.get("CF_REVOKED") == "1":
        subprocess.run(["xdg-open", "https://example.invalid/"])
        time.sleep(60)
        sys.exit(8)
    connection = socket.create_connection(("127.0.0.1", int(os.environ["CF_PORT"])))
    while True:
        ready, _, _ = select.select([0, connection], [], [])
        for source in ready:
            data = os.read(0, 65536) if source == 0 else connection.recv(65536)
            if not data: sys.exit(0)
            if source == 0: connection.sendall(data)
            else: os.write(1, data)
sys.exit(2)
"""


class CloudflareSSHTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not Path("/.dockerenv").exists():
            raise RuntimeError(
                "SSH server/password fixtures must run only inside Docker"
            )
        # StrictModes rejects authorized_keys beneath the world-writable /tmp.
        cls.shared = tempfile.TemporaryDirectory(dir=Path.home())
        cls.base = Path(cls.shared.name)
        cls.user = subprocess.check_output(["id", "-un"], text=True).strip()
        cls.password = secrets.token_hex(16)
        subprocess.run(
            ["sudo", "-n", "chpasswd"],
            input=f"{cls.user}:{cls.password}\n",
            text=True,
            check=True,
        )
        subprocess.run(["sudo", "-n", "mkdir", "-p", "/run/sshd"], check=True)
        for name in ("host", "identity", "wrong"):
            subprocess.run(
                [
                    "ssh-keygen",
                    "-q",
                    "-t",
                    "ed25519",
                    "-N",
                    "",
                    "-f",
                    str(cls.base / name),
                ],
                check=True,
            )

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ssh home ")
        self.home = Path(self.temporary.name)
        self.bin = self.home / ".local/bin"
        self.bin.mkdir(parents=True)
        self.module = self.home / ".config/dotfiles"
        self.module.mkdir(parents=True)
        (self.bin / "cloudflare-ssh").symlink_to(
            ROOT / "dot_local/bin/executable_cloudflare-ssh"
        )
        (self.module / "cloudflare_ssh.py").symlink_to(
            ROOT / "dot_config/dotfiles/cloudflare_ssh.py"
        )
        (self.bin / "cloudflared").write_text(MOCK)
        (self.bin / "cloudflared").chmod(0o755)
        (self.bin / "xdg-open").write_text('#!/bin/sh\ntouch "$CF_BROWSER_CALLED"\n')
        (self.bin / "xdg-open").chmod(0o755)
        self.calls = self.home / "calls.jsonl"
        self.cache = self.home / "cache"
        self.config = self.home / "ssh_config"
        config = (ROOT / "private_dot_ssh/private_config.tmpl").read_text()
        config = config.replace("Host rpi4 t420", "Host rpi4 t420 access-fixture")
        self.config.write_text(
            config + "\nHost access-fixture\n  HostName ssh.example.invalid\n"
        )
        self.known = self.home / "known_hosts"
        key = " ".join((self.base / "host.pub").read_text().split()[:2])
        self.known.write_text(
            f"rpi4-ssh.idanbot.uk,t420.idanbot.uk,ssh.example.invalid {key}\n"
        )
        self.environment = {
            **os.environ,
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "PATH": str(self.bin) + ":/usr/bin:/bin",
            "CF_CALLS": str(self.calls),
            "CF_CACHE": str(self.cache),
            "CF_BROWSER_CALLED": str(self.home / "browser-called"),
        }
        self.environment.pop("DOTFILES_SOURCE_DIR", None)
        self.environment.pop("SSH_AUTH_SOCK", None)
        self.server = None
        self.server_log = None

    def tearDown(self):
        if self.server is not None:
            subprocess.run(
                ["sudo", "-n", "kill", "-TERM", str(self.server.pid)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self.server.wait(timeout=5)
            self.server_log.close()
        self.temporary.cleanup()

    def start_server(self, passwords=True):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        config = self.home / "sshd_config"
        config.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {self.base / "host"}
AuthorizedKeysFile {self.base / "identity.pub"}
PidFile "{self.home / "sshd.pid"}"
UsePAM no
PasswordAuthentication {"yes" if passwords else "no"}
KbdInteractiveAuthentication no
PubkeyAuthentication yes
StrictModes yes
LogLevel ERROR
Subsystem sftp internal-sftp
""")
        self.server_log = open(self.home / "server.log", "wb")
        self.server = subprocess.Popen(
            ["sudo", "-n", "/usr/sbin/sshd", "-D", "-e", "-f", str(config)],
            stdout=subprocess.DEVNULL,
            stderr=self.server_log,
        )
        self.environment["CF_PORT"] = str(port)
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    return
            except OSError:
                if self.server.poll() is not None:
                    self.fail("disposable sshd failed to start")
                time.sleep(0.02)
        self.fail("disposable sshd did not become ready")

    def options(self):
        return [
            "-F",
            str(self.config),
            "-oControlMaster=no",
            "-oControlPersist=no",
            "-oControlPath=none",
            "-oStrictHostKeyChecking=yes",
            "-oIdentityAgent=none",
            '-oUserKnownHostsFile="' + str(self.known) + '"',
            "-oGlobalKnownHostsFile=/dev/null",
            "-oConnectTimeout=1",
            "-oIdentitiesOnly=yes",
        ]

    def ssh(self, alias="rpi4", identity="identity", extra=()):
        return [
            "/usr/bin/ssh",
            *self.options(),
            "-i",
            str(self.base / identity),
            "-l",
            self.user,
            *extra,
            alias,
            "printf fixture-ok",
        ]

    def run_tty(self, command, password=None, cancel=False, cancel_login=False):
        pid, terminal = pty.fork()
        if pid == 0:
            os.execve(command[0], command, self.environment)
        output = bytearray()
        prompts = 0
        started = time.monotonic()
        status = None
        try:
            while time.monotonic() - started < 20:
                if select.select([terminal], [], [], 0.05)[0]:
                    try:
                        part = os.read(terminal, 65536)
                    except OSError:
                        break
                    if not part:
                        break
                    output.extend(part)
                    if cancel_login and b"Access approval fixture" in output:
                        os.killpg(pid, signal.SIGINT)
                        cancel_login = False
                    count = output.lower().count(b"password:")
                    if count > prompts:
                        prompts = count
                        if cancel:
                            os.killpg(pid, signal.SIGINT)
                        elif password is not None:
                            os.write(terminal, password.encode() + b"\n")
                completed, status = os.waitpid(pid, os.WNOHANG)
                if completed:
                    break
            else:
                self.fail("SSH fixture exceeded its bounded runtime")
        finally:
            os.close(terminal)
            try:
                os.killpg(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                _, status = os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        self.assertFalse(
            b"SYNTHETIC_TOKEN_STDOUT" in output,
            "token stdout escaped into terminal output",
        )
        self.assertFalse(
            self.password.encode() in output, "password was echoed into terminal output"
        )
        return os.waitstatus_to_exitcode(status), bytes(output), prompts

    def modes(self):
        return (
            [json.loads(line)["mode"] for line in self.calls.read_text().splitlines()]
            if self.calls.exists()
            else []
        )

    def test_config_queries_are_noninteractive_for_every_managed_alias(self):
        for alias in ("rpi4", "t420", "access-fixture"):
            result = subprocess.run(
                ["ssh", "-G", "-F", str(self.config), alias],
                env=self.environment,
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertIn("proxyusefdpass yes", result.stdout)
            self.assertIn("preferredauthentications publickey,password", result.stdout)
        self.assertEqual(self.modes(), [])

    def test_browser_delay_does_not_consume_ssh_handshake_timeout(self):
        self.start_server()
        self.environment["CF_LOGIN_DELAY"] = "2"
        started = time.monotonic()
        code, output, prompts = self.run_tty(self.ssh())
        self.assertEqual(
            code, 0, "SSH did not survive a browser delay longer than ConnectTimeout"
        )
        self.assertGreater(time.monotonic() - started, 2)
        self.assertIn(b"fixture-ok", output)
        self.assertEqual(prompts, 0)
        self.assertEqual(self.modes(), ["login", "ssh"])

    def test_valid_session_and_key_work_for_each_alias_without_prompt(self):
        self.start_server()
        self.cache.touch()
        for alias in ("rpi4", "t420", "access-fixture"):
            code, output, prompts = self.run_tty(self.ssh(alias))
            self.assertEqual(code, 0, "cached-session SSH failed")
            self.assertNotIn(b"Access approval fixture", output)
            self.assertEqual(prompts, 0)

    def test_expired_native_session_is_refreshed_before_handshake(self):
        self.start_server()
        self.cache.touch()
        self.environment["CF_EXPIRED"] = "1"
        self.environment["CF_LOGIN_DELAY"] = "2"
        code, output, _ = self.run_tty(self.ssh("t420"))
        self.assertEqual(code, 0)
        self.assertIn(b"Access approval fixture", output)
        self.assertIn(b"fixture-ok", output)
        self.assertEqual(self.modes(), ["login", "ssh"])

    def multiplexed_command(self):
        control = self.home / "master.socket"
        return control, [
            {
                "-oControlMaster=no": "-oControlMaster=auto",
                "-oControlPersist=no": "-oControlPersist=5",
                "-oControlPath=none": f'-oControlPath="{control}"',
            }.get(argument, argument)
            for argument in self.ssh(extra=["-oBatchMode=yes"])
        ]

    def close_master(self, control):
        subprocess.run(
            ["ssh", "-F", str(self.config), "-S", str(control), "-O", "exit", "rpi4"],
            env=self.environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )

    def test_multiplexed_connection_survives_original_client_exit(self):
        self.start_server()
        self.cache.touch()
        control, command = self.multiplexed_command()
        try:
            code, output, _ = self.run_tty(command)
            self.assertEqual(code, 0)
            self.assertIn(b"fixture-ok", output)
            result = subprocess.run(
                command,
                env=self.environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"fixture-ok")
            self.assertEqual(self.modes(), ["token", "ssh"])
        finally:
            self.close_master(control)

    def test_multiplexed_capture_does_not_wait_for_idle_master(self):
        self.start_server()
        self.cache.touch()
        control, command = self.multiplexed_command()
        try:
            result = subprocess.run(
                command, env=self.environment, capture_output=True, timeout=3
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"fixture-ok")
            self.assertTrue(control.exists())
            self.assertNotIn(b"SYNTHETIC_TOKEN_STDOUT", result.stderr)
        finally:
            self.close_master(control)

    def test_key_rejection_falls_back_to_native_password(self):
        self.start_server()
        self.cache.touch()
        code, _, prompts = self.run_tty(
            self.ssh(identity="wrong"), password=self.password
        )
        self.assertEqual(code, 0, "native password fallback failed")
        self.assertEqual(prompts, 1)
        self.assertEqual(self.modes().count("login"), 1)

    def test_wrong_password_and_cancel_do_not_repeat_access_login(self):
        self.start_server()
        self.cache.touch()
        code, _, _ = self.run_tty(
            self.ssh(identity="wrong"), password="incorrect-fixture-password"
        )
        self.assertNotEqual(code, 0)
        before = len(self.modes())
        code, _, _ = self.run_tty(self.ssh(identity="wrong"), cancel=True)
        self.assertNotEqual(code, 0)
        self.assertEqual(self.modes()[before:].count("login"), 1)

    def test_server_can_disable_password_authentication(self):
        self.start_server(passwords=False)
        self.cache.touch()
        code, _, prompts = self.run_tty(
            self.ssh(identity="wrong"), password=self.password
        )
        self.assertNotEqual(code, 0)
        self.assertEqual(prompts, 0)

    def test_denied_and_timed_out_login_never_start_transport(self):
        self.environment["CF_DENY"] = "1"
        code, _, _ = self.run_tty(self.ssh())
        self.assertNotEqual(code, 0)
        self.assertNotIn("ssh", self.modes())
        self.environment["CF_LOGIN_DELAY"] = "5"
        self.environment["DOTFILES_ACCESS_LOGIN_TIMEOUT"] = "1"
        code, _, _ = self.run_tty(self.ssh())
        self.assertNotEqual(code, 0)
        self.assertNotIn("ssh", self.modes())

    def test_batchmode_and_headless_missing_session_never_open_browser(self):
        code, output, _ = self.run_tty(self.ssh(extra=["-oBatchMode=yes"]))
        self.assertNotEqual(code, 0)
        self.assertNotIn(b"Access approval fixture", output)
        self.assertEqual(self.modes(), ["token"])
        self.calls.unlink()
        result = subprocess.run(
            self.ssh(), env=self.environment, capture_output=True, timeout=5
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.modes(), ["token"])

    def test_headless_cached_session_succeeds_without_token_output(self):
        self.start_server()
        self.cache.touch()
        result = subprocess.run(
            self.ssh(extra=["-oBatchMode=yes"]),
            env=self.environment,
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"fixture-ok")
        self.assertNotIn(b"SYNTHETIC_TOKEN_STDOUT", result.stderr)
        self.assertEqual(self.modes(), ["token", "ssh"])

    def test_revoked_cached_session_in_batchmode_cannot_open_browser(self):
        self.cache.touch()
        self.environment["CF_REVOKED"] = "1"
        result = subprocess.run(
            self.ssh(extra=["-oBatchMode=yes"]),
            env=self.environment,
            capture_output=True,
            timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.modes(), ["token", "ssh"])
        self.assertFalse(Path(self.environment["CF_BROWSER_CALLED"]).exists())

    def test_cancelled_browser_login_never_starts_transport(self):
        self.environment["CF_LOGIN_DELAY"] = "5"
        code, _, _ = self.run_tty(self.ssh(), cancel_login=True)
        self.assertNotEqual(code, 0)
        self.assertEqual(self.modes(), ["login"])
        self.assertFalse(self.cache.exists())

    def test_connect_preflight_denial_does_not_start_transport(self):
        self.environment["CF_DENY"] = "1"
        command = [str(self.bin / "cloudflare-ssh"), "connect", "rpi4", *self.options()]
        code, _, _ = self.run_tty(command)
        self.assertNotEqual(code, 0)
        self.assertEqual(self.modes(), ["login"])

    def test_scp_authentication_and_batch_mode_use_same_managed_transport(self):
        self.start_server()
        source = self.home / "source.txt"
        source.write_text("fixture payload\n")
        destination = self.home / "copied.txt"
        command = [
            "/usr/bin/scp",
            *self.options(),
            "-i",
            str(self.base / "identity"),
            str(source),
            f"{self.user}@rpi4:{destination}",
        ]
        code, _, _ = self.run_tty(command)
        self.assertEqual(code, 0, "SCP Access bootstrap failed")
        self.assertEqual(destination.read_text(), source.read_text())
        self.cache.unlink()
        self.calls.unlink()
        result = subprocess.run(
            [command[0], "-B", *command[1:]],
            env=self.environment,
            capture_output=True,
            timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.modes(), ["token"])

    def test_scp_can_fall_back_to_native_password(self):
        self.start_server()
        source = self.home / "password-source.txt"
        source.write_text("fixture payload\n")
        destination = self.home / "password-copied.txt"
        command = [
            "/usr/bin/scp",
            *self.options(),
            "-i",
            str(self.base / "wrong"),
            str(source),
            f"{self.user}@t420:{destination}",
        ]
        code, _, prompts = self.run_tty(command, password=self.password)
        self.assertEqual(code, 0)
        self.assertEqual(prompts, 1)
        self.assertEqual(destination.read_text(), source.read_text())
        self.assertEqual(self.modes(), ["login", "ssh"])

    def test_unreachable_origin_is_not_retried_as_login_failure(self):
        self.cache.touch()
        self.environment["CF_ORIGIN_DOWN"] = "1"
        code, _, _ = self.run_tty(self.ssh())
        self.assertNotEqual(code, 0)
        self.assertEqual(self.modes(), ["login", "ssh"])


if __name__ == "__main__":
    unittest.main()
