#!/usr/bin/python3
"""Read-only Kubernetes resource picker and Zsh completion backend."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

DEFAULT_TYPES = "pods,deployments,statefulsets,services,ingresses"
TYPES = [
    "pods",
    "deployments",
    "statefulsets",
    "daemonsets",
    "services",
    "ingresses",
    "jobs",
    "cronjobs",
    "persistentvolumeclaims",
    "nodes",
]
NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*\Z")
OBJECT_NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.:-]*\Z")


class CliError(Exception):
    pass


def not_found(message):
    return re.search(r"\bNotFound\b|\bnot found\b", message, re.I)


def kubectl(args, echo=False):
    if echo:
        print(
            "full command: " + shlex.join(["kubectl", *args]),
            file=sys.stderr,
            flush=True,
        )
    try:
        return subprocess.run(
            ["kubectl", *args], capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CliError(
            f"kubectl unavailable or exceeded 15s: {type(error).__name__}"
        ) from None


def checked(args):
    result = kubectl(args)
    if result.returncode:
        raise CliError(result.stderr.strip() or "kubectl failed")
    return result.stdout


class Cache:
    def __init__(self, context, identity):
        self.context, self.identity = context, identity
        self.root = (
            Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
            / "dotfiles/kfzf"
        )
        if self.root.resolve() != self.root.absolute():
            raise CliError("refusing redirected cache directory")
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.root.chmod(0o700)

    def path(self, resource, namespace):
        key = json.dumps([self.identity, self.context, resource, namespace])
        return self.root / (hashlib.sha256(key.encode()).hexdigest() + ".json")

    def save(self, path, record):
        fd, temporary = tempfile.mkstemp(dir=self.root, prefix=".cache-")
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(record, stream)
                stream.write("\n")
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def read(self, path):
        if path.is_symlink():
            raise CliError("refusing linked cache file")
        try:
            data = json.loads(path.read_text())
            if (
                data["schema"] == 1
                and isinstance(data["items"], list)
                and isinstance(data["timestamp"], (float, int))
                and isinstance(data["failed"], bool)
            ):
                return data
        except (OSError, ValueError, KeyError, TypeError):
            pass
        return None

    def lock(self):
        fd = os.open(self.root / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        stream = os.fdopen(fd, "w")
        fcntl.flock(stream, fcntl.LOCK_EX)
        return stream

    def get(self, resource, namespace, fetch, refresh=False):
        ttl = (
            None
            if resource in {"contexts", "namespaces"}
            else (
                31 * 86400
                if resource.split(".")[0] in {"deployments", "deploy", "deployment"}
                else 86400
            )
        )
        path = self.path(resource, namespace)
        with self.lock():
            data = self.read(path)
            if (
                not refresh
                and data
                and not data["failed"]
                and (ttl is None or 0 <= time.time() - data["timestamp"] < ttl)
            ):
                return data["items"]
            try:
                items = fetch()
            except CliError as error:
                if not_found(str(error)):
                    self.save_failure(path, resource, namespace, data)
                raise
            self.save(
                path,
                {
                    "schema": 1,
                    "context": self.context,
                    "kubeconfig_identity": self.identity,
                    "resource_type": resource,
                    "namespace": namespace,
                    "timestamp": time.time(),
                    "fetched_at": datetime.now(timezone.utc).isoformat(),
                    "failed": False,
                    "items": items,
                },
            )
            return items

    def invalidate(self, resource, namespace):
        path = self.path(resource, namespace)
        with self.lock():
            self.save_failure(path, resource, namespace, self.read(path))

    def save_failure(self, path, resource, namespace, data):
        data = data or {
            "schema": 1,
            "context": self.context,
            "kubeconfig_identity": self.identity,
            "resource_type": resource,
            "namespace": namespace,
            "timestamp": 0,
            "fetched_at": None,
            "items": [],
        }
        data.update(
            failed=True,
            failure="not-found",
            failed_at=datetime.now(timezone.utc).isoformat(),
        )
        self.save(path, data)


def kubeconfig_identity():
    paths = os.environ.get("KUBECONFIG", str(Path.home() / ".kube/config")).split(
        os.pathsep
    )
    digest = hashlib.sha256()
    for name in filter(None, paths):
        path = Path(name).expanduser().absolute()
        digest.update(str(path).encode())
        try:
            digest.update(path.read_bytes())
        except FileNotFoundError:
            digest.update(b"missing")
    return digest.hexdigest()


def resources(cache, context, resource, namespace, refresh):
    def fetch():
        scope = ["--namespace", namespace] if namespace else ["--all-namespaces"]
        payload = json.loads(
            checked(
                [
                    "--context",
                    context,
                    "--request-timeout=8s",
                    "get",
                    resource,
                    *scope,
                    "-o",
                    "json",
                ]
            )
        )
        # Never persist object bodies, annotations, environment, or credentials.
        return [
            {
                "name": item["metadata"]["name"],
                "namespace": item["metadata"].get("namespace") or "_",
                "type": resource,
            }
            for item in payload["items"]
        ]

    return cache.get(resource, namespace, fetch, refresh)


def token(item):
    value = "/".join([item["namespace"], item["type"], item["name"]])
    parse_target(value)
    return value


def parse_target(target):
    parts = target.split("/")
    if len(parts) != 3 or not (
        (parts[0] == "_" or NAME.fullmatch(parts[0]))
        and NAME.fullmatch(parts[1])
        and OBJECT_NAME.fullmatch(parts[2])
    ):
        raise CliError(
            "expected namespace/type/name (use _ for cluster-scoped resources)"
        )
    return parts


def describe(cache, args, context, target):
    namespace, resource, name = parse_target(target)
    if args.namespace and namespace != "_" and namespace != args.namespace:
        raise CliError(
            "target namespace conflicts with --namespace; no command was sent"
        )
    command = ["--context", context, "--request-timeout=8s", "describe", resource, name]
    if namespace != "_":
        command += ["--namespace", namespace]
    if args.preview:
        command += ["--show-events=false"]
    result = kubectl(command, echo=True)
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if result.returncode and not_found(result.stderr):
        for scope in {args.namespace, None if namespace == "_" else namespace}:
            cache.invalidate(resource, scope)
        cache.invalidate("namespaces", None)
        print(
            "kfzf: discovery cache marked failed; the next lookup will refresh it",
            file=sys.stderr,
        )
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("query", nargs="?", default="")
    parser.add_argument("-n", "--namespace")
    parser.add_argument("-t", "--type", default=DEFAULT_TYPES)
    parser.add_argument("--context")
    parser.add_argument(
        "--refresh", action="store_true", help="refresh selected discovery lists"
    )
    parser.add_argument(
        "--complete",
        choices=["contexts", "namespaces", "types", "resources"],
        help=argparse.SUPPRESS,
    )
    parser.add_argument("--preview", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.namespace is not None and not NAME.fullmatch(args.namespace):
        parser.error("namespace must be a nonempty Kubernetes namespace name")
    types = list(dict.fromkeys(args.type.split(",")))
    if any(not NAME.fullmatch(resource) for resource in types):
        parser.error("resource types must be comma-separated API resource names")
    if args.complete == "types":
        print("\n".join(TYPES))
        return 0
    identity = kubeconfig_identity()
    if args.complete == "contexts":
        cache = Cache("", identity)
        print(
            "\n".join(
                cache.get(
                    "contexts",
                    None,
                    lambda: checked(
                        ["config", "get-contexts", "-o", "name"]
                    ).splitlines(),
                    args.refresh,
                )
            )
        )
        return 0
    context = args.context or checked(["config", "current-context"]).strip()
    if not context:
        raise CliError("no Kubernetes context selected")
    cache = Cache(context, identity)
    if args.preview or "/" in args.query:
        return describe(cache, args, context, args.preview or args.query)
    if args.complete == "namespaces":
        print(
            "\n".join(
                item["name"]
                for item in resources(cache, context, "namespaces", None, args.refresh)
            )
        )
        return 0
    items = [
        item
        for resource in types
        for item in resources(cache, context, resource, args.namespace, args.refresh)
    ]
    candidates = [token(item) for item in items]
    if args.complete:
        print("\n".join(candidates))
        return 0
    if not candidates:
        print("kfzf: no resources found", file=sys.stderr)
        return 0
    preview = [sys.executable, str(Path(__file__).resolve()), "--context", context]
    if args.namespace:
        preview += ["--namespace", args.namespace]
    preview += ["--preview"]
    # fzf escapes the substituted token; all other arguments are shell-quoted.
    picker = subprocess.run(
        [
            "fzf",
            "--query",
            args.query,
            "--delimiter",
            "/",
            "--header",
            f"Context: {context} | namespace/type/name",
            "--preview",
            "sleep 0.15; " + shlex.join(preview) + " {}",
            "--preview-window",
            "right:60%:wrap",
        ],
        input="\n".join(candidates) + "\n",
        text=True,
        capture_output=True,
    )
    if picker.returncode in {1, 130}:
        return 0
    if picker.returncode:
        raise CliError(picker.stderr.strip() or "fzf failed")
    selection = picker.stdout.strip()
    if selection not in candidates:
        raise CliError("picker returned an unknown resource")
    return describe(cache, args, context, selection)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (CliError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"kfzf: {error}", file=sys.stderr)
        sys.exit(1)
