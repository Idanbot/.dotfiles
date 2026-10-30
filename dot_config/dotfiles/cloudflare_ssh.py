#!/usr/bin/env python3
"""Cloudflare-owned login/cache handling before OpenSSH's FD-pass handshake."""

import array
import contextlib
import os
from pathlib import Path
import re
import select
import signal
import socket
import subprocess
import sys
import tempfile


class AccessError(RuntimeError):
    pass


def timeout(name, default):
    value = int(os.environ.get(name, default))
    if not 1 <= value <= 900:
        raise AccessError("timeouts must be between 1 and 900 seconds")
    return value


def ssh_settings(arguments):
    result = subprocess.run(
        ["ssh", "-G", *arguments], capture_output=True, text=True, timeout=15
    )
    if result.returncode:
        raise AccessError("unable to resolve SSH configuration; check ssh -G HOST")
    return dict(
        line.split(None, 1) for line in result.stdout.splitlines() if " " in line
    )


def parent_settings(alias):
    # Linux/WSL: replay only OpenSSH's own argv with -G, which never connects.
    # This preserves -F and command-line BatchMode overrides used by ssh/scp.
    try:
        executable = Path(f"/proc/{os.getppid()}/exe").resolve().name
        argv = Path(f"/proc/{os.getppid()}/cmdline").read_bytes().split(b"\0")
        if executable == "ssh":
            return ssh_settings([os.fsdecode(arg) for arg in argv[1:] if arg])
    except OSError:
        pass
    return ssh_settings([alias])


@contextlib.contextmanager
def terminal():
    try:
        stream = open("/dev/tty", "wb", buffering=0)
    except OSError:
        stream = None
    try:
        yield stream
    finally:
        if stream is not None:
            stream.close()


def native(command, seconds, stderr=subprocess.DEVNULL, capture=False):
    process = subprocess.Popen(
        ["cloudflared", "access", *command],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=stderr,
        start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=seconds)
        return process.returncode == 0 and (not capture or bool(output.strip()))
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


def authorize(hostname, batch=False):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", hostname):
        raise AccessError("invalid Access hostname")
    url = "https://" + hostname
    with terminal() as tty:
        interactive = tty is not None and not batch
        if interactive:
            # Native login verifies/reuses valid sessions and refreshes expired ones.
            # Its stdout is always discarded; transfer URLs go only to /dev/tty.
            if not native(
                ["login", "--quiet", url],
                timeout("DOTFILES_ACCESS_LOGIN_TIMEOUT", 300),
                tty,
            ):
                raise AccessError(
                    "Access login denied or cancelled; SSH transport was not started"
                )
        elif not native(
            ["token", "--app", url],
            timeout("DOTFILES_ACCESS_PROBE_TIMEOUT", 15),
            capture=True,
        ):
            raise AccessError(
                "Access login required; run cloudflare-ssh login HOST in an interactive terminal"
            )
    return interactive


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def supervise(endpoint, hostname, interactive, ready):
    """Own transport lifetime independently of SSH's multiplexing/fork behavior."""
    process = None
    with tempfile.TemporaryDirectory(prefix="dotfiles-access-") as temporary:
        environment = os.environ.copy()
        if not interactive:
            # cloudflared on Linux invokes xdg-open. Block only its child opener
            # if a previously valid session is revoked between probe and transport.
            opener = Path(temporary) / "xdg-open"
            opener.write_text("#!/bin/sh\nexit 1\n")
            opener.chmod(0o700)
            environment["PATH"] = temporary + os.pathsep + environment.get("PATH", "")
        try:
            process = subprocess.Popen(
                ["cloudflared", "access", "ssh", "--hostname", hostname],
                stdin=endpoint,
                stdout=endpoint,
                stderr=subprocess.DEVNULL,
                env=environment,
            )
            os.write(ready, b"1")
            os.close(ready)
            poller = select.poll()
            poller.register(
                endpoint, select.POLLHUP | select.POLLERR | select.POLLRDHUP
            )
            while process.poll() is None:
                if poller.poll(250):
                    break
            if process.poll() not in (None, 0):
                os.write(
                    2,
                    b"cloudflare-ssh: Cloudflare transport failed; check tunnel/origin connectivity\n",
                )
        finally:
            if process is not None:
                stop(process)
            endpoint.close()


def proxy(hostname, alias):
    try:
        control = socket.socket(fileno=os.dup(1))
    except OSError:
        raise AccessError(
            "proxy requires ProxyUseFdpass yes; reapply the managed SSH configuration"
        ) from None
    settings = parent_settings(alias)
    interactive = authorize(hostname, settings.get("batchmode", "yes") == "yes")
    client, transport = socket.socketpair()
    ready_read, ready_write = os.pipe()
    child = os.fork()
    if child == 0:
        # ControlPersist may outlive the original terminal and its process group.
        os.setsid()
        client.close()
        control.close()
        os.close(ready_read)
        # Close the FD-pass protocol endpoint, not the SSH transport endpoint.
        os.close(0)
        os.close(1)
        # A detached transport must not keep capture_output() pipes open for
        # ControlPersist's lifetime. SSH itself still reports transport errors.
        if not os.isatty(2):
            null = os.open(os.devnull, os.O_WRONLY)
            os.dup2(null, 2)
            os.close(null)
        try:
            supervise(transport, hostname, interactive, ready_write)
        except (OSError, subprocess.SubprocessError):
            os._exit(1)
        os._exit(0)
    transport.close()
    os.close(ready_write)
    try:
        readable, _, _ = select.select([ready_read], [], [], 5)
        if not readable or os.read(ready_read, 1) != b"1":
            raise AccessError("unable to start Cloudflare transport")
        rights = array.array("i", [client.fileno()])
        control.sendmsg([b"\0"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, rights)])
    finally:
        os.close(ready_read)
        client.close()
        control.close()


def main(arguments):
    mode, *args = arguments
    if mode == "proxy" and 1 <= len(args) <= 2:
        proxy(args[0], args[-1])
    elif mode in {"login", "connect"} and args:
        target, *extra = args
        settings = ssh_settings([target, *extra])
        authorize(settings["hostname"], settings.get("batchmode", "yes") == "yes")
        if mode == "connect":
            os.execvp("ssh", ["ssh", target, *extra])
    else:
        raise AccessError("invalid helper arguments")


if __name__ == "__main__":

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        main(sys.argv[1:])
    except KeyboardInterrupt:
        sys.exit(130)
    except AccessError as error:
        print(f"cloudflare-ssh: {error}", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print(
            "cloudflare-ssh: Access preflight timed out; retry login interactively or check connectivity",
            file=sys.stderr,
        )
        sys.exit(1)
    except (OSError, ValueError, subprocess.SubprocessError):
        # Never echo native command output, tokens, URLs, or process arguments.
        print(
            "cloudflare-ssh: Access preflight/transport failed; check authentication, helper configuration, and timeout settings",
            file=sys.stderr,
        )
        sys.exit(1)
