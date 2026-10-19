#!/usr/bin/env python3
"""Audit repository-pinned versions against OSV without installing packages."""

import argparse
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import quote
import urllib.error
import urllib.request

import yaml

ROOT = Path(__file__).resolve().parent.parent
QUERY = "https://api.osv.dev/v1/querybatch"
VULN = "https://api.osv.dev/v1/vulns/"

# Versions whose upstream release tags differ from their package pin.
SPECIAL = {
    "cloud.cloudflared": ("GIT", "cloudflare/cloudflared", "{version}"),
    "cloud.aws_cli": ("GIT", "aws/aws-cli", "{version}"),
    "ai_tools.bun": ("GIT", "oven-sh/bun", "bun-v{version}"),
    "languages.go": ("GIT", "golang/go", "go{version}"),
    "languages.node": ("GIT", "nodejs/node", "v{version}"),
    "languages.python": ("GIT", "python/cpython", "v{version}"),
    "languages.rust": ("GIT", "rust-lang/rust", "{version}"),
    "cloud.kubectl": ("GIT", "kubernetes/kubernetes", "v{version}"),
    "cloud.terraform": ("GIT", "hashicorp/terraform", "v{version}"),
    "core.ast_grep": ("GIT", "ast-grep/ast-grep", "{version}"),
    "ai_tools.codex_cli": None,
    "ai_tools.antigravity_cli": None,
    "languages.java": None,
    "languages.cargo": None,
}


def version_key(value):
    return tuple(int(part) for part in re.findall(r"\d+", str(value)))


def coordinate(ident, pin, meta):
    if ident in SPECIAL:
        spec = SPECIAL[ident]
        if spec is None:
            return None
        ecosystem, repo, tag = spec
        return {"package": {"ecosystem": ecosystem,
                "name": f"https://github.com/{repo}.git"},
                "version": tag.format(version=pin)}
    source = meta.get("source")
    if source == "npm" and meta.get("package"):
        return {"package": {"ecosystem": "npm", "name": meta["package"]},
                "version": str(pin)}
    if source in {"pypi", "uv", "uvx"} and meta.get("package"):
        return {"package": {"ecosystem": "PyPI", "name": meta["package"]},
                "version": str(pin)}
    repo = meta.get("repo")
    if source == "github" and repo:
        return {"package": {"ecosystem": "GIT",
                            "name": f"https://github.com/{repo}.git"},
                "version": f"v{pin}"}
    return None


def post_json(url, payload):
    request = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise RuntimeError(
            f"OSV request failed ({type(exc).__name__}); retry the audit") from None


def get_json(url):
    headers = {}
    token = os.environ.get("GITHUB_TOKEN", "")
    if url.startswith("https://api.github.com/") and token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise RuntimeError(
            f"OSV request failed ({type(exc).__name__}); retry the audit") from None


def stable_version(value):
    return bool(re.fullmatch(r"\d+(?:\.\d+)+(?:\+\d+)?", str(value)))


def release_versions(entry, fetch=get_json):
    package = entry["package"]
    ecosystem, name = package["ecosystem"], package["name"]
    if ecosystem == "npm":
        encoded = quote(name, safe="@")
        data = fetch(f"https://registry.npmjs.org/{encoded}")
        versions = data.get("versions", {})
        return [version for version in versions if stable_version(version)]
    if ecosystem == "PyPI":
        data = fetch(f"https://pypi.org/pypi/{quote(name, safe='')}/json")
        return [version for version in data.get("releases", {}) if stable_version(version)]
    if ecosystem == "GIT":
        prefix = entry["version"].removesuffix(entry["pin"])
        suffix = ""
        repo = name.removeprefix("https://github.com/").removesuffix(".git")
        tags = fetch(f"https://api.github.com/repos/{repo}/tags?per_page=100")
        versions = []
        for item in tags:
            tag = item.get("name", "")
            if not tag.startswith(prefix) or (suffix and not tag.endswith(suffix)):
                continue
            value = tag[len(prefix):len(tag) - len(suffix) if suffix else None]
            if stable_version(value):
                versions.append(value)
        return versions
    return []


def upgrade_candidates(entry, root, fetch=get_json):
    policy = json.loads((root / "scripts/update-policy.json").read_text())
    rule = policy.get(entry["id"], "stable")
    versions = sorted(
        {value for value in release_versions(entry, fetch)
         if stable_version(value) and version_key(value) > version_key(entry["pin"])},
        key=version_key)
    if not versions:
        return []
    width = {"major": 1, "minor": 2}.get(rule, 0)
    compatible = [value for value in versions
                  if not width or version_key(value)[:width] == version_key(entry["pin"])[:width]]
    latest = versions[-1]
    selected = {}
    if compatible:
        selected[compatible[-1]] = ["latest-compatible"]
    stable_labels = ["latest-stable"]
    if width and version_key(latest)[:width] != version_key(entry["pin"])[:width]:
        stable_labels.append("outside compatibility policy")
    selected.setdefault(latest, []).extend(stable_labels)
    prefix = entry["version"][:entry["version"].find(entry["pin"])]
    suffix = entry["version"][len(prefix) + len(entry["pin"]):]
    return [{"version": value,
             "query_version": f"{prefix}{value}{suffix}",
             "labels": labels}
            for value, labels in selected.items()]


def load_pins(root):
    packages = yaml.safe_load((root / "packages.yaml").read_text())
    metadata = yaml.safe_load((root / "packages.meta.yaml").read_text())
    scanned, skipped = [], []
    for section, tools in packages.items():
        if not isinstance(tools, dict):
            continue
        for name, pin in tools.items():
            ident = f"{section}.{name}"
            if str(pin).lower() in {"distro", "standalone"}:
                skipped.append((ident, "not pinned to a stable upstream package version"))
                continue
            if not re.match(r"^\d", str(pin)):
                skipped.append((ident, "manifest value is not a version number"))
                continue
            meta = metadata.get(section, {}).get(name, {})
            coord = coordinate(ident, pin, meta)
            if coord is None:
                skipped.append((ident, "no reliable OSV package coordinate"))
                continue
            scanned.append({"id": ident, "pin": str(pin),
                            "ecosystem": coord["package"]["ecosystem"], **coord})
    return scanned, skipped


def fixed_versions(vulnerability):
    versions = set()
    for affected in vulnerability.get("affected", []):
        for version_range in affected.get("ranges", []):
            for event in version_range.get("events", []):
                if event.get("fixed"):
                    versions.add(str(event["fixed"]))
    return sorted(versions, key=version_key)


def severity(vulnerability):
    values = []
    for item in vulnerability.get("severity", []):
        match = re.search(r"(?:^|/)([0-9]+(?:\.[0-9]+)?)(?:$|/)",
                          str(item.get("score", "")))
        if match:
            score = float(match[1])
            values.append("critical" if score >= 9 else "high" if score >= 7
                          else "moderate" if score >= 4 else "low")
    for source in [vulnerability.get("database_specific", {}),
                   *(affected.get("database_specific", {}) for affected in vulnerability.get("affected", [])),
                   *(affected.get("ecosystem_specific", {}) for affected in vulnerability.get("affected", []))]:
        value = str(source.get("severity", "")).lower()
        if value in {"critical", "high", "moderate", "medium", "low"}:
            values.append(value)
    rank = {"low": 1, "moderate": 2, "medium": 2, "high": 3, "critical": 4}
    return max(values, key=rank.get) if values else "unspecified"


def audit(root, request=post_json, fetch=get_json, resolve_candidates=upgrade_candidates):
    scanned, skipped = load_pins(root)
    unique = {}
    for entry in scanned:
        package = entry["package"]
        key = (package["ecosystem"], package["name"], entry["version"])
        unique.setdefault(key, []).append(entry)
    keys = list(unique)
    payload = {"queries": [
        {"package": {"ecosystem": eco, "name": name}, "version": version}
        for eco, name, version in keys]}
    results = request(QUERY, payload).get("results", []) if keys else []
    if len(results) != len(keys):
        raise RuntimeError("OSV returned an incomplete batch response")
    if any(result.get("next_page_token") for result in results):
        raise RuntimeError("OSV response was paginated; refusing a partial audit")
    findings = []
    vulnerability_cache = {}
    for key, result in zip(keys, results):
        for item in result.get("vulns", []):
            vuln = vulnerability_cache.setdefault(item["id"], None)
            if vuln is None:
                vuln = fetch(VULN + item["id"])
                vulnerability_cache[item["id"]] = vuln
            for entry in unique[key]:
                findings.append({"id": entry["id"], "pin": entry["pin"],
                                 "ecosystem": entry["ecosystem"],
                                 "coordinate": key,
                                 "vulnerability": vuln,
                                 "fixed": fixed_versions(vuln),
                                 "severity": severity(vuln)})
    advice = candidate_advice(root, scanned, findings, request, fetch, resolve_candidates,
                              vulnerability_cache)
    for finding in findings:
        finding["recommendation"] = advice.get(
            finding["coordinate"],
            "WARNING: no newer candidate with lower known OSV severity was established")
    findings.sort(key=lambda item: (
        {"critical": 0, "high": 1, "moderate": 2, "medium": 2,
         "low": 3}.get(item["severity"], 4),
        item["id"], item["vulnerability"].get("id", "")))
    return scanned, skipped, findings


def candidate_advice(root, scanned, findings, request, fetch, resolve_candidates,
                     vulnerability_cache):
    """Compare only the latest policy-compatible and latest-stable candidates."""
    affected = {}
    entries = {}
    current_vulns = {}
    for entry in scanned:
        key = (entry["package"]["ecosystem"], entry["package"]["name"], entry["version"])
        entries.setdefault(key, entry)
    for finding in findings:
        current_vulns.setdefault(finding["coordinate"], {})[
            finding["vulnerability"]["id"]] = finding["vulnerability"]
    candidates, lookup_errors = {}, {}
    for key in current_vulns:
        try:
            candidates[key] = resolve_candidates(entries[key], root, fetch)
        except (RuntimeError, ValueError, KeyError, OSError, TimeoutError) as exc:
            candidates[key] = []
            lookup_errors[key] = type(exc).__name__
        for candidate in candidates[key]:
            candidate_key = (key[0], key[1], candidate["query_version"])
            affected.setdefault(candidate_key, []).append((key, candidate))

    candidate_keys = list(affected)
    queries = {"queries": [
        {"package": {"ecosystem": ecosystem, "name": name}, "version": version}
        for ecosystem, name, version in candidate_keys]}
    results = request(QUERY, queries).get("results", []) if candidate_keys else []
    if len(results) != len(candidate_keys):
        raise RuntimeError("OSV returned an incomplete candidate batch response")
    if any(result.get("next_page_token") for result in results):
        raise RuntimeError("OSV candidate response was paginated; refusing partial advice")

    severities = {}
    for key, result in zip(candidate_keys, results):
        ids = [item["id"] for item in result.get("vulns", [])]
        records = []
        for vuln_id in ids:
            if vuln_id not in vulnerability_cache:
                vulnerability_cache[vuln_id] = fetch(VULN + vuln_id)
            records.append(vulnerability_cache[vuln_id])
        severities[key] = [severity(item) for item in records]

    advice = {}
    rank = {"low": 1, "moderate": 2, "medium": 2, "high": 3, "critical": 4}
    for key, options in candidates.items():
        current = list(current_vulns[key].values())
        current_levels = [severity(item) for item in current]
        current_known = all(level in rank for level in current_levels)
        current_max = max((rank.get(level, 0) for level in current_levels), default=0)
        improved = []
        for option in options:
            candidate_key = (key[0], key[1], option["version"])
            levels = severities.get(candidate_key, [])
            clean = not levels
            lower = (current_known and all(level in rank for level in levels) and
                     bool(levels) and max(rank[level] for level in levels) < current_max)
            if clean or lower:
                improved.append((not clean, "latest-compatible" not in option["labels"],
                                 option, levels, clean))
        if improved:
            _, _, option, levels, clean = min(improved, key=lambda item: (item[0], item[1]))
            label = " and ".join(option["labels"])
            if clean:
                message = f"Recommend {option['version']} ({label}; no OSV advisories)"
            else:
                before = max(rank[level] for level in current_levels)
                after = max(rank[level] for level in levels)
                names = {1: "low", 2: "moderate", 3: "high", 4: "critical"}
                message = (f"Recommend {option['version']} ({label}; maximum severity "
                           f"{names[before]} to {names[after]})")
            advice[key] = message
        elif key in lookup_errors:
            advice[key] = (f"WARNING: candidate lookup failed ({lookup_errors[key]}); "
                           "no safer upgrade could be established")
        else:
            advice[key] = ("WARNING: no newer candidate with no advisories or lower "
                           "known maximum severity was found")
    return advice


def markdown(scanned, skipped, findings, upgrade_url):
    distinct = {
        (entry.get("package", {}).get("ecosystem", ""),
         entry.get("package", {}).get("name", entry["id"]),
         entry.get("version", entry["pin"]))
        for entry in scanned
    }
    lines = [
        "# Pinned-version vulnerability audit", "",
        "Exact repository pins were queried against OSV. This advisory check does not guarantee that a package is vulnerability-free.",
        "", f"- Pinned entries with mapped OSV coordinates: **{len(scanned)}**",
        f"- Distinct package/version queries: **{len(distinct)}**",
        f"- Pins without reliable OSV coordinates: **{len(skipped)}**",
        f"- Vulnerable pinned package/version pairs: **{len(findings)}**", ""]
    if findings:
        lines += [
            "## Findings", "",
            "| Severity | Pin | Advisory | Summary | Fixed versions / upgrade width | Safer candidate |",
            "|---|---|---|---|---|---|"]
        for finding in findings:
            vuln = finding["vulnerability"]
            ident = vuln.get("id", "OSV")
            aliases = [alias for alias in vuln.get("aliases", [])
                       if alias.startswith(("CVE-", "GHSA-"))]
            label = ", ".join([ident, *aliases[:2]])
            fixed = finding["fixed"]
            if finding.get("ecosystem") == "GIT":
                remediation = (f"{len(fixed)} upstream commit fix(es) listed; "
                               "review advisory and release notes")
            elif not fixed:
                remediation = "No fixed version listed; review upstream advisory"
            else:
                pin_major = version_key(finding["pin"])[:1]
                tick = chr(96)
                remediation = ", ".join(
                    f"{tick}{ver}{tick} ({'commit fix; review release' if finding.get('ecosystem') == 'GIT' else 'same-major fix' if version_key(ver)[:1] == pin_major else 'major upgrade'})"
                    for ver in fixed)
            summary = re.sub(r"\s+", " ", vuln.get("summary", ""))[:180].replace("|", "\\|")
            lines.append(
                f"| {finding['severity']} | {chr(96)}{finding['id']}@{finding['pin']}{chr(96)} | "
                f"[{label}](https://osv.dev/vulnerability/{ident}) | {summary} | "
                f"{remediation} | {finding.get('recommendation', 'Not assessed')} |")
        lines += ["", "Review fixes against the repository compatibility policy before changing pins."]
    else:
        lines += ["No known advisories matched the queried pinned versions."]
    if skipped:
        lines += ["", "## Not queried", "",
                  "Entries without exact stable upstream pins or reliable OSV coordinates:", ""]
        lines.extend(f"- {chr(96)}{ident}{chr(96)}: {reason}" for ident, reason in skipped)
    lines += [
        "", f"The weekly [stable-version report]({upgrade_url}) separately lists latest compatible and latest stable releases, including major/minor availability.", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--upgrade-report-url", default=
                        "https://github.com/Idanbot/.dotfiles/issues/34")
    args = parser.parse_args()
    scanned, skipped, findings = audit(args.source)
    report = markdown(scanned, skipped, findings, args.upgrade_report_url)
    if args.output:
        args.output.write_text(report)
    print(report)
    for finding in findings:
        message = (f"Pinned advisory: {finding['id']}@{finding['pin']}; "
                   f"{finding['recommendation']}")
        message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::warning title={finding['severity']} pinned vulnerability::{message}",
              file=sys.stderr)


if __name__ == "__main__":
    main()
