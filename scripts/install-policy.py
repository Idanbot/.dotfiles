#!/usr/bin/python3
"""Read-only installation preflight and per-run stable release resolution."""

import argparse
import concurrent.futures
import datetime
import functools
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

import catalog as software

ROOT = Path(__file__).resolve().parent.parent
ROLLING = {"core.github_cli", "cloud.aws_cli", "cloud.gcloud", "cloud.helm",
           "cloud.terraform", "cloud.azure_cli", "cloud.cloudflared"}
AWS_FINGERPRINT = "FB5DB77FD5C118B80511ADA8A6310ACC4672475C"


def version(value):
    match = re.search(r"\d+(?:\.\d+)+(?:\+\d+)?", str(value))
    return match.group() if match else ""


def order(value):
    parts = tuple(int(part) for part in re.findall(r"\d+", version(value)))
    return parts + (0,) * (6 - len(parts))


def stable(value):
    return bool(re.fullmatch(r"\d+(?:\.\d+)+(?:\+\d+)?", value))


@functools.lru_cache(maxsize=256)
def fetch(url):
    args = ["curl", "--proto", "=https", "--tlsv1.2", "-fsSL",
            "--connect-timeout", "10", "--max-time", "30", "--retry", "2"]
    token = os.environ.get("GH_TOKEN", os.environ.get("GITHUB_TOKEN", ""))
    if url.startswith("https://api.github.com/") and token:
        args += ["-H", f"Authorization: Bearer {token}"]
    try:
        result = subprocess.run([*args, url], capture_output=True, timeout=100)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError(f"Cannot resolve {url}; network request failed or timed out") from None
    if result.returncode:
        # Never echo headers, tokens, or arbitrary server output into logs.
        raise ValueError(f"Cannot resolve {url}; check network/API rate limits and retry")
    return result.stdout.decode("utf-8")


def get_json(url):
    return json.loads(fetch(url))


def release_version(release):
    tag = release.get("tag_name", "").removeprefix("bun-").removeprefix("azure-cli-").removeprefix("v")
    return tag if stable(tag) and not release.get("prerelease") and not release.get("draft") else ""


def github(repo, major=None):
    base = f"https://api.github.com/repos/{repo}/releases"
    latest = get_json(base + "/latest")
    newest = release_version(latest)
    if not newest:
        raise ValueError(f"No stable latest release for {repo}")
    if major is None or order(newest)[0] == major:
        return newest, latest
    # Search older maintained majors rather than accepting a breaking upgrade.
    for page in range(1, 11):
        releases = get_json(f"{base}?per_page=100&page={page}")
        candidates = [(release_version(item), item) for item in releases]
        candidates = [(v, item) for v, item in candidates if v and order(v)[0] == major]
        if candidates:
            return max(candidates, key=lambda item: order(item[0]))
        if len(releases) < 100:
            break
    raise ValueError(f"No stable release found for {repo} major {major}; review the repository pin")


def upstream(entry, meta, major=None):
    ident = entry["id"]
    if ident == "cloud.aws_cli":
        versions = re.findall(r"^([0-9]+\.[0-9]+\.[0-9]+)\r?$", fetch(
            "https://raw.githubusercontent.com/aws/aws-cli/v2/CHANGELOG.rst"), re.M)
        versions = [v for v in versions if major is None or order(v)[0] == major]
        if not versions:
            raise ValueError("AWS CLI stable major unavailable")
        return max(versions, key=order), {}
    if ident == "cloud.gcloud":
        latest = str(get_json("https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json")["version"])
        # Google increments the first component for SDK releases. Do not cross
        # an installed major, even though it is not a conventional SemVer major.
        return (entry["current"] if major is not None and order(latest)[0] != major else latest), {}
    if ident == "cloud.kubectl":
        return fetch("https://dl.k8s.io/release/stable.txt").strip().removeprefix("v"), {}
    if ident == "languages.go":
        versions = [item["version"].removeprefix("go") for item in get_json("https://go.dev/dl/?mode=json") if item.get("stable")]
        return max(versions, key=order), {}
    if ident in {"languages.rust", "languages.cargo"}:
        text = fetch("https://static.rust-lang.org/dist/channel-rust-stable.toml")
        return re.search(r'^version = "([0-9.]+)', text, re.M).group(1), {}
    if ident == "languages.node":
        versions = [item["version"].removeprefix("v") for item in get_json("https://nodejs.org/dist/index.json")]
        return max((v for v in versions if stable(v)), key=order), {}
    if ident == "languages.python":
        tags = get_json("https://api.github.com/repos/python/cpython/tags?per_page=100")
        versions = [item["name"].removeprefix("v") for item in tags]
        return max((v for v in versions if stable(v)), key=order), {}
    if ident == "languages.java":
        feature = get_json("https://api.adoptium.net/v3/info/available_releases")["most_recent_feature_release"]
        data = get_json(f"https://api.adoptium.net/v3/assets/latest/{feature}/hotspot?architecture=x64&image_type=jdk&os=linux")
        return data[0]["release_name"].removeprefix("jdk-"), {}
    if ident == "cloud.terraform":
        return github("hashicorp/terraform", major)
    if ident == "cloud.azure_cli":
        return github("Azure/azure-cli", major)
    if meta.get("source") == "npm":
        package = meta.get("package", ident.split(".")[1]).replace("/", "%2f")
        return get_json(f"https://registry.npmjs.org/{package}/latest")["version"], {}
    if meta.get("source") == "pypi":
        package = meta.get("package", ident.split(".")[1])
        return get_json(f"https://pypi.org/pypi/{package}/json")["info"]["version"], {}
    if meta.get("repo"):
        return github(meta["repo"], major)
    raise ValueError("No stable upstream resolver; use the version audit report")


def checksum(text, asset):
    for line in text.splitlines():
        fields = line.split()
        if fields and re.fullmatch(r"[0-9a-fA-F]{64}", fields[0]):
            if len(fields) == 1 or fields[-1].lstrip("*") == asset:
                return fields[0].lower()
    raise ValueError(f"No SHA256 found for {asset}")


def integrity(entry, release, arch):
    ident, target = entry["id"], entry["target"]
    if ident in {"core.github_cli", "cloud.cloudflared"}:
        asset = (f"gh_{target}_linux_{arch}.tar.gz" if ident == "core.github_cli"
                 else f"cloudflared-linux-{arch}.deb")
        item = next((item for item in release.get("assets", []) if item["name"] == asset), {})
        digest = item.get("digest") or ""
        if re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            return digest
        if ident == "core.github_cli":
            sums = fetch(f"https://github.com/cli/cli/releases/download/v{target}/gh_{target}_checksums.txt")
            return "sha256:" + checksum(sums, asset)
        raise ValueError(f"Missing release-asset SHA256 for {asset}; no unverified fallback")
    if ident == "cloud.helm":
        asset = f"helm-v{target}-linux-{arch}.tar.gz"
        return "sha256:" + checksum(fetch(f"https://get.helm.sh/{asset}.sha256sum"), asset)
    if ident == "cloud.terraform":
        asset = f"terraform_{target}_linux_{arch}.zip"
        url = f"https://releases.hashicorp.com/terraform/{target}/terraform_{target}_SHA256SUMS"
        return "sha256:" + checksum(fetch(url), asset)
    if ident == "cloud.aws_cli":
        return "aws-pgp:" + AWS_FINGERPRINT
    return "apt-signature"


def selected(root, sections):
    registry = json.loads((root / "scripts/sections.json").read_text())
    unknown = set(sections) - registry.keys()
    if unknown:
        raise ValueError("Unknown sections: " + ", ".join(sorted(unknown)))
    if not any(registry[section]["manifest"] for section in sections):
        return []
    entries = software.catalog()
    return [entry for entry in entries if any(
        any(entry["id"] == prefix or entry["id"].startswith(prefix + ".")
            for prefix in registry[section]["manifest"])
        and entry["id"] not in registry[section].get("exclude", [])
        for section in sections) and (stable(entry["requested"]) or entry["id"] in ROLLING)]


def resolve(entry, meta, arch):
    _, observed = software.probe(entry)
    entry = {**entry, "current": observed["version"] or "", "path": observed["path"],
             "target": entry["requested"], "policy": "same-major" if entry["id"] in ROLLING else "repo-minimum"}
    try:
        latest, _ = upstream(entry, meta)
        if not stable(latest):
            raise ValueError("Upstream did not supply a stable numeric version")
        entry["latest"] = latest
        if entry["id"] in ROLLING:
            baseline = entry["requested"] if stable(entry["requested"]) else entry["current"] or latest
            target, release = upstream(entry, meta, order(baseline)[0])
            # Never regress below the tested repository baseline.
            if stable(entry["requested"]) and order(target) < order(entry["requested"]):
                raise ValueError("Upstream latest is older than the repository baseline")
            entry["target"] = target
            entry["integrity"] = integrity(entry, release, arch)
    except (ValueError, KeyError, TypeError, AttributeError, subprocess.TimeoutExpired) as error:
        entry["resolution_warning"] = str(error)
        if entry["id"] in ROLLING:
            entry["error"] = str(error)
    return entry


def planned_action(entry):
    if not entry["path"]:
        return "install", "missing"
    if entry["current"] and stable(entry["target"]) and order(entry["current"]) >= order(entry["target"]):
        return "skip; preserve equal/newer version", "unchanged"
    state = Path(os.environ.get("DOTFILES_STATE_DIR", str(Path.home() / ".local/state/dotfiles")))
    ledger = state / "installed.tsv"
    if ledger.is_file():
        for line in ledger.read_text().splitlines():
            fields = line.split("\t")
            if len(fields) >= 4 and (entry["path"] == fields[3]
                                    or str(Path(entry["path"]).resolve()).startswith(fields[3] + "/")):
                return "update after ownership/digest verification", "recorded-dotfiles"
    if entry["id"] in {"cloud.gcloud", "cloud.azure_cli"}:
        package = "google-cloud-cli" if entry["id"] == "cloud.gcloud" else "azure-cli"
        result = subprocess.run(["dpkg-query", "-S", str(Path(entry["path"]).resolve())],
                                capture_output=True, text=True, timeout=5)
        if result.returncode == 0 and package + ":" in result.stdout:
            return "update via signed APT repository", "apt"
    if entry["id"] == "languages.python":
        return "install side-by-side via uv; keep system Python", "external"
    return "skip; preserve unowned/modified executable", "unowned"


def host_checks(home, sections):
    checks = []
    os_release = platform.freedesktop_os_release()
    supported = os_release.get("ID") == "ubuntu" and os_release.get("VERSION_ID") == "24.04"
    if not supported and os.environ.get("DOTFILES_ALLOW_UNSUPPORTED") != "1":
        checks.append(("FAIL", "Supported host required: Ubuntu 24.04 native or WSL"))
    if platform.machine() not in {"x86_64", "aarch64", "arm64"}:
        checks.append(("FAIL", "Only amd64 and arm64 release assets are supported"))
    if not home.is_dir() or not os.access(home, os.W_OK | os.X_OK):
        checks.append(("FAIL", f"Home directory is not writable: {home}"))
    free = shutil.disk_usage(home).free
    if free < 200 * 1024 ** 2:
        checks.append(("FAIL", "Less than 200 MiB free in home; free space before installation"))
    elif free < 5 * 1024 ** 3:
        checks.append(("WARN", "Less than 5 GiB free in home; large profiles may need more space"))
    if os.geteuid() != 0 and not shutil.which("sudo"):
        checks.append(("FAIL", "sudo is required for selected installation sections"))
    if str(home / ".local/bin") not in os.environ.get("PATH", "").split(os.pathsep):
        checks.append(("WARN", "~/.local/bin is absent from PATH; restart the shell after installation"))
    if (Path("/var/lib/dpkg/updates").is_dir()
            and any(path.name.isdigit() for path in Path("/var/lib/dpkg/updates").iterdir())):
        checks.append(("FAIL", "Interrupted dpkg operation; review 'sudo dpkg --configure -a' before retrying"))
    audit = subprocess.run(["/usr/bin/dpkg", "--audit"], capture_output=True, text=True, timeout=10)
    if audit.returncode or audit.stdout.strip():
        checks.append(("FAIL", "dpkg reports incomplete package configuration; review 'sudo dpkg --audit' before retrying"))
    if "languages" in sections and any(os.environ.get(key) for key in ("VIRTUAL_ENV", "CONDA_PREFIX")):
        checks.append(("WARN", "Active virtual environment detected; project environments will not be changed"))
    return checks


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or path.parent.resolve() != path.parent.absolute():
        raise ValueError("Refusing redirected version-plan path")
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def say(level, message):
    color = os.environ.get("DOTFILES_COLOR_ACTIVE") == "true" or (
        sys.stdout.isatty() and os.environ.get("TERM") != "dumb")
    color = color and not os.environ.get("NO_COLOR") and os.environ.get("DOTFILES_COLOR") != "never"
    codes = {"HIGH": "31", "FAIL": "31", "WARN": "33", "LOW": "33", "INFO": "36"}
    label = f"[{level}]"
    if color:
        label = f"\033[{codes[level]}m{label}\033[0m"
    print(f"{label} {message}", flush=True)
    event_log = os.environ.get("DOTFILES_EVENT_LOG")
    if event_log:
        event = {"time": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                 "run_id": os.environ.get("DOTFILES_RUN_ID", "unknown"),
                 "section": "preflight", "level": level.lower(), "message": message}
        with open(event_log, "a") as stream:
            stream.write(json.dumps(event) + "\n")


def report(entries):
    warnings = []
    for entry in entries:
        _, observed = software.probe(entry)
        current, latest = observed["version"] or "", entry.get("latest", "")
        if entry.get("resolution_warning"):
            warnings.append(("WARN", f"{entry['id']}: freshness unknown; {entry['resolution_warning']}"))
        elif not current:
            warnings.append(("WARN", f"{entry['id']}: installed version unavailable; latest stable {latest or 'unknown'}"))
        elif latest and order(current) < order(latest):
            severity = "HIGH" if order(latest)[0] > order(current)[0] else "LOW"
            warnings.append((severity, f"{entry['id']}: installed {current}; latest stable {latest} "
                             f"({'new major; review before upgrading' if severity == 'HIGH' else 'minor/patch update available'}); "
                             f"policy {entry['policy']}, run target {entry['target']}"))
    for level, message in warnings:
        say(level, message)
    if not warnings:
        say("INFO", "All checked tools are current (as resolved at preflight)")
    return [{"severity": level.lower(), "message": message} for level, message in warnings]


def main():
    global ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["preflight", "report", "get"], nargs="?", default="preflight")
    parser.add_argument("--source", type=Path, default=ROOT)
    parser.add_argument("--sections", default="core,languages,cloud,ai")
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--tool")
    parser.add_argument("--field", default="target")
    args = parser.parse_args()
    ROOT = args.source.resolve()
    software.ROOT = ROOT
    if args.command == "get":
        data = json.loads(args.plan.read_text())
        print(data["tools"].get(args.tool, {}).get(args.field, ""))
        return
    if args.command == "report":
        data = json.loads(args.plan.read_text())
        warnings = report(data["tools"].values())
        atomic_json(args.plan.with_name("update-warnings.json"), warnings)
        return
    sections = args.sections.split(",")
    checks = host_checks(Path.home(), sections)
    if args.resume and args.plan and not args.plan.is_file() and not (args.plan.parent / "checkpoints/preflight.done").exists():
        # A failure before preflight produced a plan may resolve for the first
        # time. A previously completed stage must never silently re-resolve.
        args.resume = False
    if args.resume:
        if not args.plan or not args.plan.is_file():
            raise ValueError("Resume has no resolved version plan; start a new installation run")
        data = json.loads(args.plan.read_text())
        if data.get("schema") != 1 or data.get("sections") != sections or data.get("source") != str(ROOT):
            raise ValueError("Version plan inputs changed; start a new installation run")
    else:
        metadata = yaml.safe_load((ROOT / "packages.meta.yaml").read_text())
        entries = selected(ROOT, sections)
        arch = "amd64" if platform.machine() == "x86_64" else "arm64"
        def resolve_one(entry):
            group, key = entry["id"].split(".")
            return resolve(entry, metadata.get(group, {}).get(key, {}), arch)
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            tools = list(pool.map(resolve_one, entries))
        for entry in tools:
            entry["action"], entry["ownership"] = planned_action(entry)
        data = {"schema": 1, "source": str(ROOT), "sections": sections,
                "resolved_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "tools": {entry["id"]: entry for entry in tools}}
    for entry in data["tools"].values():
        if entry.get("error"):
            checks.append(("FAIL", entry["id"] + ": " + entry["error"]))
    data["checks"] = checks
    if args.json:
        print(json.dumps(data, indent=2))
    else:
        for level, message in checks:
            say(level, message)
        for entry in data["tools"].values():
            say("INFO", f"{entry['id']}: {entry['current'] or 'missing'} -> {entry['target']} "
                f"({entry['policy']}); {entry['path'] or 'not on PATH'}; "
                f"{entry['ownership']}: {entry['action']}")
        say("INFO", "No credentials, project pins, or package configuration changed by preflight")
    if any(level == "FAIL" for level, _ in checks):
        raise SystemExit(1)
    if args.plan and not args.resume:
        atomic_json(args.plan, data)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"preflight: {error}") from error
