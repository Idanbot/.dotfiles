"""Audit allowlisted observed software, with explicit consent for OSV requests."""

import datetime
import importlib.util
import re

from .local_review import ReviewError, entries, numeric_version, validate_receipt
from .metadata import load_metadata

LEVELS = {"none", "low", "moderate", "high", "critical", "unspecified"}


def audit_module(root):
    spec = importlib.util.spec_from_file_location(
        "dotfiles_osv_audit", root / "scripts/audit-vulnerabilities.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def advisory_id(value):
    return isinstance(value, str) and bool(
        re.fullmatch(
            r"(?:GHSA-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}"
            r"|(?:CVE|GO|RUSTSEC|PYSEC|OSV|MAL|GSD|PSF)-[0-9]{4}-[0-9]{1,12})",
            value,
        )
    )


def validate_cache(data, root):
    if (
        not isinstance(data, dict)
        or set(data) != {"schema", "kind", "as_of", "tools"}
        or type(data["schema"]) is not int
        or data["schema"] != 1
        or data["kind"] != "dotfiles-advisories"
    ):
        raise ReviewError("invalid-advisory-data")
    if not isinstance(data["as_of"], str) or not re.fullmatch(
        r"\d{4}-\d{2}-\d{2}", data["as_of"]
    ):
        raise ReviewError("invalid-advisory-data")
    datetime.date.fromisoformat(data["as_of"])
    known = {entry["id"] for entry in entries(root)}
    if not isinstance(data["tools"], list) or len(data["tools"]) > len(known):
        raise ReviewError("invalid-advisory-data")
    seen = set()
    for item in data["tools"]:
        if (
            not isinstance(item, dict)
            or set(item) != {"id", "version", "advisories"}
            or not isinstance(item["id"], str)
            or item["id"] not in known
            or item["id"] in seen
            or numeric_version(item["version"]) != item["version"]
            or item["version"] is None
        ):
            raise ReviewError("invalid-advisory-data")
        seen.add(item["id"])
        if not isinstance(item["advisories"], list) or len(item["advisories"]) > 1000:
            raise ReviewError("invalid-advisory-data")
        for advisory in item["advisories"]:
            if (
                not isinstance(advisory, dict)
                or set(advisory) != {"id", "severity", "fixed"}
                or not advisory_id(advisory["id"])
                or not isinstance(advisory["severity"], str)
                or advisory["severity"] not in LEVELS
                or not isinstance(advisory["fixed"], list)
                or any(
                    value is None or numeric_version(value) != value
                    for value in advisory["fixed"]
                )
            ):
                raise ReviewError("invalid-advisory-data")
    return data


def audit(root, receipt, *, online=False, cache=None, request=None, fetch=None):
    validate_receipt(receipt, root)
    if online and cache is not None:
        raise ReviewError("choose-online-or-offline-data")
    if cache is not None:
        validate_cache(cache, root)
    module = audit_module(root)
    metadata = load_metadata(root / "packages.meta.yaml")
    plans = {}
    for item in receipt["tools"]:
        if not item["version"]:
            continue
        group, key = item["id"].split(".", 1)
        query = module.coordinate(
            item["id"], item["version"], metadata.get(group, {}).get(key, {})
        )
        if query:
            plans[item["id"]] = query
    if online:
        request = request or module.post_json
        fetch = fetch or module.get_json
        ids = list(plans)
        results = (
            module.batch_results(
                request(module.QUERY, {"queries": [plans[name] for name in ids]}),
                len(ids),
            )
            if ids
            else []
        )
        cached_tools = []
        retrieved = {}
        for ident, result in zip(ids, results):
            findings = []
            for summary in result.get("vulns", []):
                name = summary["id"]
                if not advisory_id(name):
                    raise ReviewError("invalid-advisory-id")
                if name not in retrieved:
                    retrieved[name] = fetch(module.VULN + name)
                vulnerability = retrieved[name]
                if (
                    not isinstance(vulnerability, dict)
                    or vulnerability.get("id") != name
                ):
                    raise ReviewError("mismatched-advisory-id")
                findings.append(
                    {
                        "id": name,
                        "severity": module.severity(vulnerability),
                        "fixed": sorted(
                            {
                                value
                                for value in module.fixed_versions(vulnerability)
                                if numeric_version(value) == value
                            }
                        ),
                    }
                )
            installed = next(item for item in receipt["tools"] if item["id"] == ident)
            cached_tools.append(
                {"id": ident, "version": installed["version"], "advisories": findings}
            )
        cache = {
            "schema": 1,
            "kind": "dotfiles-advisories",
            "as_of": datetime.datetime.now(datetime.timezone.utc).date().isoformat(),
            "tools": cached_tools,
        }
        validate_cache(cache, root)
    observations = (
        {(item["id"], item["version"]): item["advisories"] for item in cache["tools"]}
        if cache
        else {}
    )
    tools = []
    for item in receipt["tools"]:
        findings = observations.get((item["id"], item["version"]))
        if not item["version"]:
            status = "missing" if item["state"] == "missing" else "unobserved"
        elif item["id"] not in plans:
            status = "unsupported"
        elif findings is None:
            status = "unknown"
        else:
            status = "advisories" if findings else "no-known-advisories"
        tools.append(
            {
                "id": item["id"],
                "version": item["version"],
                "status": status,
                "advisories": findings or [],
            }
        )
    return {
        "schema": 1,
        "kind": "dotfiles-installed-audit",
        "source": "online" if online else "offline",
        "as_of": cache["as_of"] if cache else None,
        "coverage": {
            status: sum(item["status"] == status for item in tools)
            for status in (
                "advisories",
                "no-known-advisories",
                "unknown",
                "unsupported",
                "unobserved",
                "missing",
            )
        },
        "tools": tools,
    }, cache
