#!/usr/bin/python3
"""Offline discovery catalog; explicit refresh probes versions, never connects."""

import argparse
import concurrent.futures
import datetime
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    raise SystemExit("Catalog requires system python3-yaml; rerun the core section")

ROOT = Path(__file__).resolve().parent.parent
COMMANDS = {
    "github_cli": ["gh"],
    "aws_cli": ["aws"],
    "azure_cli": ["az"],
    "claude_cli": ["claude"],
    "codex_cli": ["codex"],
    "antigravity_cli": ["agy"],
    "java": ["java"],
    "python": ["python3", "python"],
    "rust": ["rustc"],
    "typescript": ["tsc"],
    "tealdeer": ["tldr"],
    "ast_grep": ["ast-grep", "sg"],
}
# Only these known binaries are executed, and only with version-only arguments.
PROBES = {
    name: ["--version"]
    for name in [
        "chezmoi",
        "fzf",
        "fdfind",
        "fd",
        "rg",
        "bat",
        "batcat",
        "eza",
        "lazygit",
        "btop",
        "starship",
        "gh",
        "jq",
        "gojq",
        "yq",
        "pigz",
        "zstd",
        "htop",
        "zoxide",
        "direnv",
        "delta",
        "hyperfine",
        "duf",
        "sops",
        "lazydocker",
        "tldr",
        "curlie",
        "ast-grep",
        "gitleaks",
        "rustc",
        "cargo",
        "node",
        "npm",
        "tsc",
        "python3",
        "python",
        "uv",
        "atuin",
        "nvim",
        "usql",
        "iredis",
        "pgloader",
        "docker",
        "ansible",
        "k9s",
        "aws",
        "cloudflared",
        "s5cmd",
        "kcat",
        "stern",
        "helmfile",
        "kubectx",
        "kubens",
        "kubecolor",
        "kubectl-radar",
        "kitty",
        "tmuxp",
        "herdr",
        "git-credential-manager",
        "claude",
        "codex",
        "agy",
        "opencode",
        "omp",
        "bun",
        "serena",
        "context-mode",
        "graphify",
        "rtk",
        "yt-dlp",
        "rmpc",
        "cava",
        "psql",
        "redis-cli",
        "mysql",
        "mariadb",
        "tailscale",
    ]
}
PROBES.update(
    {
        "kubectl": ["version", "--client", "-o", "json"],
        "helm": ["version", "--short"],
        "go": ["version"],
        "gcloud": ["version", "--format=json"],
        "az": ["version", "--output", "json"],
        "java": ["-version"],
        "tmux": ["-V"],
        "ssh": ["-V"],
    }
)


def catalog():
    manifest = yaml.safe_load((ROOT / "packages.yaml").read_text())
    metadata = yaml.safe_load((ROOT / "packages.meta.yaml").read_text())
    config = json.loads((ROOT / "dot_config/dotfiles/catalog.json").read_text())
    result = []
    for category, tools in manifest.items():
        for name, requested in tools.items():
            meta = metadata.get(category, {}).get(name, {})
            entry = {
                "id": f"{category}.{name}",
                "category": category,
                "commands": COMMANDS.get(name, [meta.get("binary", name)]),
                "requested": str(requested),
                "source": meta.get("source", "unknown"),
                "owner": meta.get("owner", "unknown"),
                "tags": config["categories"].get(category, []) + [name, category],
                "description": name.replace("_", " "),
                "upstream": "",
            }
            if meta.get("repo"):
                entry["upstream"] = "https://github.com/" + meta["repo"]
            elif meta.get("source") == "npm":
                entry["upstream"] = "https://www.npmjs.com/package/" + meta.get(
                    "package", name
                )
            elif meta.get("source") == "pypi":
                entry["upstream"] = (
                    "https://pypi.org/project/" + meta.get("package", name) + "/"
                )
            overlay = config["entries"].get(entry["id"], {})
            entry.update(
                {key: value for key, value in overlay.items() if key != "tags"}
            )
            entry["tags"] = sorted(set(entry["tags"] + overlay.get("tags", [])))
            result.append(entry)
    for extra in config["extras"]:
        result.append(
            {
                "requested": "unmanaged",
                "source": "external",
                "owner": "unmanaged",
                "description": extra["id"],
                "upstream": "",
                **extra,
            }
        )
    return sorted(result, key=lambda entry: entry["id"])


def snapshot_path():
    return (
        Path(
            os.environ.get(
                "DOTFILES_STATE_DIR", str(Path.home() / ".local/state/dotfiles")
            )
        )
        / "catalog.json"
    )


def locate(entry):
    for command in entry["commands"]:
        path = shutil.which(command)
        if path:
            # sg is also a Unix group-switching utility; do not misidentify it.
            if command == "sg" and Path(path).resolve() == Path("/usr/bin/sg"):
                continue
            return command, path
    return None, None


def probe(entry):
    command, path = locate(entry)
    record = {
        "path": path,
        "command": command,
        "signature": signature(path),
        "version": None,
        "probe": "unavailable",
    }
    if path and command in PROBES:
        try:
            output = subprocess.run(
                [path, *PROBES[command]],
                check=False,
                capture_output=True,
                text=True,
                timeout=3,
                env={**os.environ, "NO_COLOR": "1"},
            )
            if output.returncode != 0:
                record["probe"] = "failed"
            else:
                text = output.stdout + output.stderr
                if command in {"gcloud", "az", "kubectl"}:
                    data = json.loads(output.stdout)
                    if command == "gcloud":
                        text = data.get("Google Cloud SDK", "")
                    elif command == "az":
                        text = data.get("azure-cli", "")
                    else:
                        text = data.get("clientVersion", {}).get("gitVersion", "")
                match = re.search(
                    r"(?<![\d.])\d+\.\d+(?:\.\d+)*(?:[+.-][\w.-]+)?",
                    text,
                )
                record.update(
                    version=match.group() if match else None,
                    probe="ok" if match else "unknown",
                )
        except subprocess.TimeoutExpired:
            record["probe"] = "timeout"
        except (OSError, UnicodeError, ValueError, TypeError, AttributeError):
            record["probe"] = "failed"
    elif path:
        record["probe"] = "not-supported"
    return entry["id"], record


def signature(path):
    if path:
        try:
            stat = Path(path).stat()
            return {
                "resolved": str(Path(path).resolve()),
                "mtime_ns": stat.st_mtime_ns,
                "size": stat.st_size,
            }
        except OSError:
            pass
    return None


def refresh(entries):
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        records = dict(pool.map(probe, entries))
    data = {
        "schema": 1,
        "observed_at": datetime.datetime.now(datetime.UTC).isoformat(),
        "entries": records,
    }
    path = snapshot_path()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".catalog-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Refreshed {len(entries)} entries: {path}")


def view(entries):
    path = snapshot_path()
    data = json.loads(path.read_text()) if path.exists() else {}
    if path.exists() and (
        not isinstance(data, dict)
        or data.get("schema") != 1
        or not isinstance(data.get("entries"), dict)
        or any(not isinstance(record, dict) for record in data["entries"].values())
    ):
        raise ValueError("Invalid catalog snapshot; repair with 'dot tools refresh'")
    for entry in entries:
        command, executable = locate(entry)
        cached = data.get("entries", {}).get(entry["id"], {})
        current = cached.get("path") == executable and cached.get(
            "signature"
        ) == signature(executable)
        entry.update(
            command=command,
            path=executable,
            resolved_path=str(Path(executable).resolve()) if executable else None,
            status="installed"
            if executable
            else ("package" if not entry["commands"] else "missing"),
            installed_version=cached.get("version") if executable and current else None,
            probe_status="stale"
            if cached and not current
            else cached.get("probe", "not-refreshed"),
            observed_at=data.get("observed_at") if cached else None,
        )
    return entries


def details(entry):
    print(f"{entry['id']}\n{entry['description']}\n")
    for name in (
        "category",
        "status",
        "requested",
        "installed_version",
        "probe_status",
        "path",
        "resolved_path",
        "source",
        "owner",
        "upstream",
        "observed_at",
    ):
        print(f"{name.replace('_', ' ').title()}: {entry.get(name) or '-'}")
    print("Commands: " + ", ".join(entry["commands"]))
    print("Tags: " + ", ".join(entry["tags"]))
    for example in entry.get("examples", []):
        print("Example (not executed): " + example)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("query", nargs="*", help="search terms, or refresh/show ID")
    parser.add_argument("--category")
    parser.add_argument("--tag", action="append", default=[])
    parser.add_argument(
        "--available",
        action="store_true",
        help="include missing candidates and non-executable packages",
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--pick", action="store_true", help="fzf picker with read-only details preview"
    )
    args = parser.parse_args()
    entries = catalog()
    if args.query == ["refresh"]:
        refresh(entries)
        return 0
    entries = view(entries)
    if args.query and args.query[0] == "show":
        if len(args.query) != 2:
            parser.error("show requires one catalog ID")
        entry = next((item for item in entries if item["id"] == args.query[1]), None)
        if entry is None:
            parser.error("unknown catalog ID")
        if args.json:
            print(json.dumps(entry, indent=2))
        else:
            details(entry)
        return 0
    terms = [term.casefold() for term in args.query]
    selected = []
    for entry in entries:
        haystack = " ".join(
            [entry["id"], entry["description"], *entry["tags"], *entry["commands"]]
        ).casefold()
        if (not args.available and entry["status"] != "installed") or (
            args.category and entry["category"] != args.category
        ):
            continue
        if not all(tag.casefold() in entry["tags"] for tag in args.tag) or not all(
            term in haystack for term in terms
        ):
            continue
        selected.append(entry)
    if args.json:
        print(json.dumps(selected, indent=2))
    elif args.pick:
        if not shutil.which("fzf"):
            parser.error("fzf is missing; install the terminal section")
        if not selected:
            print("No matching entries. Try --available.")
            return 0
        rows = "\n".join(
            f"{entry['id']}\t{entry['id']}  [{entry['status']}] {entry['description']}"
            for entry in selected
        )
        preview = (
            shlex.join([sys.executable, str(Path(__file__).resolve()), "show"]) + " {1}"
        )
        result = subprocess.run(
            [
                "fzf",
                "--delimiter=\t",
                "--with-nth=2..",
                "--preview",
                preview,
                "--preview-window=right:60%:wrap",
            ],
            check=False,
            input=rows,
            text=True,
            stdout=subprocess.PIPE,
        )
        if result.returncode in (1, 130):
            return 0
        if result.returncode:
            return result.returncode
        chosen = result.stdout.split("\t", 1)[0].strip()
        entry = next((item for item in selected if item["id"] == chosen), None)
        if entry:
            details(entry)
    else:
        if selected:
            print(
                f"{'CATEGORY':12} {'ENTRY':32} {'REQUESTED':15} {'OBSERVED':15} PATH / STATUS"
            )
        for entry in selected:
            print(
                f"{entry['category']:12} {entry['id']:32} {entry['requested']:15} {entry['installed_version'] or '?':15} {entry['path'] or entry['status']}"
            )
        if not selected:
            print("No matching entries. Try --available.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, yaml.YAMLError) as error:
        print(f"Catalog error: {error}", file=sys.stderr)
        raise SystemExit(1)
