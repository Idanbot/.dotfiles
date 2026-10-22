"""Shared, read-only release filtering and compatibility policy.

Network adapters receive their caller's fetch function; this module performs no I/O
at import time and needs no audit-only dependencies.
"""

import re
from urllib.parse import quote


def version(value):
    match = re.search(r"\d+(?:\.\d+)+(?:\+\d+)?", str(value))
    return match.group() if match else ""


def order(value):
    parts = tuple(int(part) for part in re.findall(r"\d+", version(value)))
    return parts + (0,) * max(0, 6 - len(parts))


def stable(value):
    return bool(re.fullmatch(r"\d+(?:\.\d+)+(?:\+\d+)?", str(value)))


def compatible(value, baseline, rule):
    width = {"major": 1, "minor": 2}.get(rule, 0)
    return not width or order(value)[:width] == order(baseline)[:width]


def candidates(versions, baseline):
    return sorted(
        {
            value
            for value in versions
            if stable(value) and order(value) > order(baseline)
        },
        key=order,
    )


def latest_compatible(versions, baseline, rule="stable", requested=None):
    if requested is not None:
        if not stable(requested) or requested not in versions:
            raise ValueError("Requested version is not an eligible stable release")
        # Explicit review may change release lines, but not release eligibility.
        return requested
    choices = [
        value
        for value in candidates(versions, baseline)
        if compatible(value, baseline, rule)
    ]
    return choices[-1] if choices else baseline


def candidate_options(versions, baseline, rule="stable"):
    choices = candidates(versions, baseline)
    if not choices:
        return []
    selected = {}
    within = [value for value in choices if compatible(value, baseline, rule)]
    if within:
        selected[within[-1]] = ["latest-compatible"]
    labels = ["latest-stable"]
    if not compatible(choices[-1], baseline, rule):
        labels.append("outside compatibility policy")
    selected.setdefault(choices[-1], []).extend(labels)
    return [{"version": value, "labels": labels} for value, labels in selected.items()]


def release_version(release):
    tag = (
        release.get("tag_name", "")
        .removeprefix("bun-")
        .removeprefix("azure-cli-")
        .removeprefix("v")
    )
    return (
        tag
        if stable(tag) and not release.get("prerelease") and not release.get("draft")
        else ""
    )


def _engine_clause(actual, clause):
    match = re.fullmatch(
        r"(>=|<=|>|<|\^|~|=)?v?(\d+|[xX*])(?:\.(\d+|[xX*]))?(?:\.(\d+|[xX*]))?", clause
    )
    if not match:
        return False
    op = match[1] or "="
    fields = list(match.groups()[1:])
    width = next(
        (
            i
            for i, field in enumerate(fields)
            if field is None or field in {"x", "X", "*"}
        ),
        3,
    )
    if any(field not in {None, "x", "X", "*"} for field in fields[width:]):
        return False
    base = tuple(int(field) for field in fields[:width]) + (0,) * (3 - width)
    if width == 0:
        return op == "="
    upper = list(base)
    upper[width - 1] += 1
    upper = tuple(upper)
    if op == "=":
        return actual == base if width == 3 else base <= actual < upper
    if op == ">=":
        return actual >= base
    if op == ">":
        return actual > base if width == 3 else actual >= upper
    if op == "<":
        return actual < base
    if op == "<=":
        return actual <= base if width == 3 else actual < upper
    if op == "~":
        boundary = (base[0] + 1, 0, 0) if width == 1 else (base[0], base[1] + 1, 0)
    else:
        # Caret ranges stop at the first nonzero component, including 0.x.
        index = next((i for i in range(width) if base[i]), width - 1)
        boundary = base[:index] + (base[index] + 1,) + (0,) * (2 - index)
    return base <= actual < boundary


def node_engine_matches(node, requirement):
    """Evaluate common npm engine ranges; reject unknown or malformed syntax."""
    if not stable(node) or not isinstance(requirement, str):
        return False
    actual = order(node)[:3]
    for alternative in requirement.split("||"):
        alternative = alternative.strip()
        interval = re.fullmatch(
            r"(v?\d+(?:\.\d+){0,2})\s+-\s+(v?\d+(?:\.\d+){0,2})", alternative
        )
        if interval:
            alternative = f">={interval[1]} <={interval[2]}"
        alternative = re.sub(r"(>=|<=|>|<|\^|~|=)\s+", r"\1", alternative)
        clauses = alternative.split()
        if clauses and all(_engine_clause(actual, clause) for clause in clauses):
            return True
    return False


def npm_versions(data, node=None):
    ceiling = data.get("dist-tags", {}).get("latest", "")
    if not stable(ceiling):
        raise ValueError("npm latest tag is not a stable version")
    return [
        value
        for value, item in data.get("versions", {}).items()
        if stable(value)
        and order(value) <= order(ceiling)
        and (
            node is None
            or not item.get("engines", {}).get("node")
            or node_engine_matches(node, item["engines"]["node"])
        )
    ]


def pypi_versions(data):
    return [
        value
        for value, files in data.get("releases", {}).items()
        if stable(value) and any(not item.get("yanked", False) for item in files)
    ]


def git_versions(entry, fetch):
    prefix, found, suffix = entry["version"].partition(entry["pin"])
    if not found:
        raise ValueError("Git query version does not contain its pin")
    repo = (
        entry["package"]["name"]
        .removeprefix("https://github.com/")
        .removesuffix(".git")
    )
    tags = fetch(f"https://api.github.com/repos/{repo}/tags?per_page=100")
    versions = []
    for item in tags:
        tag = item.get("name", "")
        if tag.startswith(prefix) and (not suffix or tag.endswith(suffix)):
            value = tag[len(prefix) : len(tag) - len(suffix) if suffix else None]
            if stable(value):
                versions.append(value)
    return versions


def release_versions(ident, meta, fetch, node=None, entry=None):
    """Return available releases, or None when a caller-specific adapter is needed."""
    ecosystem = entry.get("package", {}).get("ecosystem") if entry else None
    source = meta.get("source")
    if (
        ecosystem == "npm"
        or source == "npm"
        or ident in {"languages.npm", "languages.typescript"}
    ):
        name = (
            entry["package"]["name"]
            if ecosystem == "npm"
            else meta.get("package", ident.split(".")[-1])
        )
        return npm_versions(
            fetch(f"https://registry.npmjs.org/{quote(name, safe='@')}"), node
        )
    if ecosystem == "PyPI" or source in {"pypi", "uv", "uvx"}:
        name = (
            entry["package"]["name"]
            if ecosystem == "PyPI"
            else meta.get("package", ident.split(".")[-1])
        )
        return pypi_versions(
            fetch(f"https://pypi.org/pypi/{quote(name, safe='')}/json")
        )
    if ecosystem == "GIT":
        return git_versions(entry, fetch)
    if ident == "languages.node":
        return [
            item["version"].removeprefix("v")
            for item in fetch("https://nodejs.org/dist/index.json")
        ]
    if ident == "languages.go":
        return [
            item["version"].removeprefix("go")
            for item in fetch("https://go.dev/dl/?mode=json&include=all")
            if item.get("stable")
        ]
    if ident == "languages.python":
        return [
            item["name"].removeprefix("v")
            for item in fetch(
                "https://api.github.com/repos/python/cpython/tags?per_page=100"
            )
        ]
    return None
