"""Allowlisted, offline machine reviews. Never serialize raw config or probe output."""

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import tempfile

import catalog as software


class ReviewError(ValueError):
    """Only public diagnostic codes may cross the CLI interface."""


def read_local(path, limit=4 * 1024 * 1024):
    path = Path(path).absolute()
    if path.parent.resolve() != path.parent or path.is_symlink():
        raise ReviewError("redirected-input")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ReviewError("nonregular-input")
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ReviewError("input-too-large")
    return data.decode("utf-8")


def read_json(path):
    return json.loads(read_local(path))


def write_private(path, text):
    path = Path(path).absolute()
    if path.parent.resolve() != path.parent or path.exists() or path.is_symlink():
        raise ReviewError("output-exists-or-redirected")
    # Output directories are created only in response to an explicit --output.
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(
        prefix=".dotfiles-review-", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(text)
        # Unlike replace(), link() also refuses a destination created concurrently.
        os.link(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def numeric_version(value):
    if not isinstance(value, str) or len(value) > 64:
        return None
    if re.fullmatch(r"\d+(?:\.\d+){1,3}(?:\+\d+)?", value):
        return value
    build = re.fullmatch(
        r"(\d+\.\d+\.\d+(?:\.\d+)?)(?:\+g[0-9a-f]{7,40}|-[0-9a-f]{7,40})", value
    )
    return build[1] if build else None


def state_root():
    return Path(
        os.environ.get("DOTFILES_STATE_DIR", str(Path.home() / ".local/state/dotfiles"))
    )


def entries(root):
    software.ROOT = root
    return software.catalog()


def section_names(root):
    return set(json.loads((root / "scripts/sections.json").read_text()))


def selection(root):
    path = state_root() / "selected-sections"
    if not path.exists():
        return []
    values = read_local(path, 4096).strip().split(",")
    if not set(values) <= section_names(root):
        raise ReviewError("invalid-installed-selection")
    return sorted(set(values))


def host_platform():
    release = platform.freedesktop_os_release()
    os_name = (
        "ubuntu-24.04"
        if release.get("ID") == "ubuntu" and release.get("VERSION_ID") == "24.04"
        else "unsupported"
    )
    wsl = os.environ.get("DOTFILES_WSL", "auto")
    simulated = wsl in {"true", "1", "yes"}
    detected = (
        bool(os.environ.get("WSL_DISTRO_NAME"))
        or "microsoft" in platform.release().lower()
    )
    return {
        "os": os_name,
        "mode": "wsl" if simulated or (wsl == "auto" and detected) else "native",
        "arch": {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(
            platform.machine(), "unknown"
        ),
    }


def source_commit(root):
    directory = root / ".git"
    if not directory.is_dir() or directory.is_symlink():
        return None
    try:
        head = read_local(directory / "HEAD", 4096).strip()
        if head.startswith("ref: refs/"):
            ref = head.removeprefix("ref: ")
            if not re.fullmatch(r"refs/[A-Za-z0-9_./-]+", ref) or ".." in ref:
                return None
            if (directory / ref).is_file():
                head = read_local(directory / ref, 4096).strip()
            elif (directory / "packed-refs").is_file():
                head = next(
                    (
                        line.split()[0]
                        for line in read_local(directory / "packed-refs").splitlines()
                        if len(line.split()) == 2 and line.split()[1] == ref
                    ),
                    "",
                )
        return head if re.fullmatch(r"[a-f0-9]{40}|[a-f0-9]{64}", head) else None
    except (OSError, ValueError):
        return None


def receipt(root):
    cache = software.snapshot_path()
    data = read_json(cache) if cache.exists() else {"schema": 1, "entries": {}}
    if (
        not isinstance(data, dict)
        or type(data.get("schema")) is not int
        or data["schema"] != 1
        or not isinstance(data.get("entries"), dict)
    ):
        raise ReviewError("invalid-catalog-snapshot")
    ledger = state_root() / "installed.tsv"
    recorded = set()
    if ledger.exists():
        for line in read_local(ledger).splitlines():
            fields = line.split("\t")
            if len(fields) != 6:
                raise ReviewError("invalid-install-ledger")
            recorded.add(fields[3])
    tools = []
    for entry in entries(root):
        _, executable = software.locate(entry)
        cached = data["entries"].get(entry["id"], {})
        if not isinstance(cached, dict):
            raise ReviewError("invalid-catalog-snapshot")
        current = (
            bool(executable)
            and cached.get("path") == executable
            and cached.get("signature") == software.signature(executable)
        )
        version = numeric_version(cached.get("version")) if current else None
        status = (
            "observed"
            if version
            else "unknown"
            if current
            else "stale"
            if executable
            else "missing"
        )
        management = (
            "recorded-unverified"
            if executable in recorded
            else "external-or-unrecorded"
            if executable
            else "unavailable"
        )
        tools.append(
            {
                "id": entry["id"],
                "version": version,
                "state": status,
                "management": management,
            }
        )
    manifest = hashlib.sha256(
        (root / "packages.yaml").read_bytes()
        + (root / "packages.meta.yaml").read_bytes()
    ).hexdigest()
    return {
        "schema": 1,
        "kind": "dotfiles-receipt",
        "platform": host_platform(),
        "manifest_sha256": manifest,
        "source_commit": source_commit(root),
        "sections": selection(root),
        "tools": tools,
    }


def validate_receipt(data, root):
    if not isinstance(data, dict) or set(data) != {
        "schema",
        "kind",
        "platform",
        "manifest_sha256",
        "source_commit",
        "sections",
        "tools",
    }:
        raise ReviewError("invalid-receipt")
    if (
        type(data["schema"]) is not int
        or data["schema"] != 1
        or data["kind"] != "dotfiles-receipt"
    ):
        raise ReviewError("invalid-receipt")
    host = data["platform"]
    if (
        not isinstance(host, dict)
        or set(host) != {"os", "mode", "arch"}
        or host["os"] not in {"ubuntu-24.04", "unsupported"}
        or host["mode"] not in {"native", "wsl"}
        or host["arch"] not in {"amd64", "arm64", "unknown"}
    ):
        raise ReviewError("invalid-receipt")
    if not isinstance(data["manifest_sha256"], str) or not re.fullmatch(
        r"[a-f0-9]{64}", data["manifest_sha256"]
    ):
        raise ReviewError("invalid-receipt")
    if data["source_commit"] is not None and (
        not isinstance(data["source_commit"], str)
        or not re.fullmatch(r"[a-f0-9]{40}|[a-f0-9]{64}", data["source_commit"])
    ):
        raise ReviewError("invalid-receipt")
    if (
        not isinstance(data["sections"], list)
        or any(
            not isinstance(item, str) or item not in section_names(root)
            for item in data["sections"]
        )
        or len(data["sections"]) != len(set(data["sections"]))
    ):
        raise ReviewError("invalid-receipt")
    known = {entry["id"] for entry in entries(root)}
    if not isinstance(data["tools"], list) or len(data["tools"]) > len(known):
        raise ReviewError("invalid-receipt")
    seen = set()
    for item in data["tools"]:
        if (
            not isinstance(item, dict)
            or set(item) != {"id", "version", "state", "management"}
            or not isinstance(item["id"], str)
            or item["id"] not in known
            or item["id"] in seen
        ):
            raise ReviewError("invalid-receipt")
        seen.add(item["id"])
        if not isinstance(item["state"], str) or item["state"] not in {
            "observed",
            "unknown",
            "stale",
            "missing",
        }:
            raise ReviewError("invalid-receipt")
        if (
            item["version"] is not None
            and numeric_version(item["version"]) != item["version"]
        ):
            raise ReviewError("invalid-receipt")
        if (item["version"] is not None) != (item["state"] == "observed"):
            raise ReviewError("invalid-receipt")
        if not isinstance(item["management"], str) or item["management"] not in {
            "recorded-unverified",
            "external-or-unrecorded",
            "unavailable",
        }:
            raise ReviewError("invalid-receipt")
    return data


def compare_receipts(before, after, root):
    for data in (before, after):
        validate_receipt(data, root)
    changes = []
    for key in ("platform", "sections", "manifest_sha256", "source_commit"):
        if before[key] != after[key]:
            changes.append({"field": key, "before": before[key], "after": after[key]})
    left = {item["id"]: item for item in before["tools"]}
    right = {item["id"]: item for item in after["tools"]}
    for key in sorted(left.keys() | right.keys()):
        if left.get(key) != right.get(key):
            changes.append(
                {"tool": key, "before": left.get(key), "after": right.get(key)}
            )
    return {"schema": 1, "kind": "dotfiles-receipt-comparison", "changes": changes}


def check_local(root):
    checks = []

    def result(code, state):
        checks.append({"id": code, "status": state})

    for label, filename, parser in (
        ("shell.zsh.syntax", ".zshrc", ["/usr/bin/zsh", "-f", "-n"]),
        ("shell.bash.syntax", ".bashrc", ["/bin/bash", "--noprofile", "--norc", "-n"]),
        ("shell.profile.syntax", ".profile", ["/bin/sh", "-n"]),
    ):
        path = Path.home() / filename
        if not path.exists() or path.is_symlink() or not Path(parser[0]).is_file():
            result(label, "unavailable")
            continue
        # Syntax-only parsers never source the startup file. Discard all diagnostics.
        try:
            document = read_local(path, 1024 * 1024)
            with tempfile.TemporaryDirectory() as home:
                completed = subprocess.run(
                    parser,
                    input=document,
                    text=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    env={"HOME": home, "PATH": "/usr/bin:/bin", "LC_ALL": "C"},
                )
            result(label, "ok" if completed.returncode == 0 else "attention")
        except (OSError, subprocess.TimeoutExpired):
            result(label, "unavailable")
        except ValueError:
            result(label, "attention")
    for label, path in (
        ("state.permissions", state_root()),
        ("mcp.agy.permissions", Path.home() / ".gemini/config/mcp_config.json"),
        ("mcp.opencode.permissions", Path.home() / ".config/opencode/opencode.json"),
        ("mcp.omp.permissions", Path.home() / ".omp/agent/mcp.json"),
    ):
        try:
            info = path.lstat()
            valid_type = (
                stat.S_ISDIR(info.st_mode)
                if label == "state.permissions"
                else stat.S_ISREG(info.st_mode)
            )
            result(
                label,
                "attention"
                if not valid_type
                or path.absolute().parent.resolve() != path.absolute().parent
                or stat.S_IMODE(info.st_mode) & 0o077
                else "ok",
            )
        except FileNotFoundError:
            result(label, "unavailable")
    try:
        receipt(root)
        result("catalog.integrity", "ok")
    except (OSError, ValueError, TypeError):
        result("catalog.integrity", "attention")
    return {"schema": 1, "kind": "dotfiles-local-check", "checks": checks}
