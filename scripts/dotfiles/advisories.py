"""Validate OSV details before caching them or deriving package-specific advice."""

import re


def validate_advisory_id(value):
    if not isinstance(value, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._-]{0,199}", value
    ):
        raise RuntimeError("OSV returned an invalid advisory ID")


def object_list(record, key):
    value = record.get(key, [])
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise RuntimeError("OSV returned malformed advisory details")
    return value


def validate_advisory(record, expected_id):
    validate_advisory_id(expected_id)
    if not isinstance(record, dict) or record.get("id") != expected_id:
        raise RuntimeError("OSV returned mismatched advisory details")
    affected = object_list(record, "affected")
    if not affected:
        raise RuntimeError("OSV returned advisory details without affected packages")
    if "aliases" in record and (
        not isinstance(record["aliases"], list)
        or any(not isinstance(value, str) for value in record["aliases"])
    ):
        raise RuntimeError("OSV returned malformed advisory aliases")
    if "summary" in record and not isinstance(record["summary"], str):
        raise RuntimeError("OSV returned malformed advisory summary")
    for item in [record, *affected]:
        for key in ("database_specific", "ecosystem_specific"):
            if key in item and not isinstance(item[key], dict):
                raise RuntimeError("OSV returned malformed advisory details")
        for level in object_list(item, "severity"):
            if not isinstance(level.get("score"), str):
                raise RuntimeError("OSV returned malformed advisory severity")
    for item in affected:
        if "package" in item:
            package = item["package"]
            if not isinstance(package, dict) or any(
                not isinstance(package.get(key), str) or not package[key]
                for key in ("ecosystem", "name")
            ):
                raise RuntimeError("OSV returned malformed affected package")
        for version_range in object_list(item, "ranges"):
            if "repo" in version_range and not isinstance(version_range["repo"], str):
                raise RuntimeError("OSV returned malformed affected repository")
            events = object_list(version_range, "events")
            if not events:
                raise RuntimeError("OSV returned an advisory range without events")
            for event in events:
                if (
                    len(event) != 1
                    or not set(event) <= {"introduced", "fixed", "last_affected", "limit"}
                    or any(
                        not isinstance(value, str) or not value
                        for value in event.values()
                    )
                ):
                    raise RuntimeError("OSV returned malformed advisory range event")
    return record


def scoped_advisory(record, package):
    """Retain only affected records/ranges belonging to the queried coordinate."""
    matches = []
    git = package["ecosystem"] == "GIT"
    repository = package["name"].rstrip("/").removesuffix(".git")
    for item in record["affected"]:
        actual = item.get("package", {})
        exact = all(
            actual.get(key) == package[key] for key in ("ecosystem", "name")
        )
        if package["ecosystem"] == actual.get("ecosystem") == "PyPI":
            exact = re.sub(r"[-_.]+", "-", actual["name"]).lower() == re.sub(
                r"[-_.]+", "-", package["name"]
            ).lower()
        ranges = (
            [
                value for value in item.get("ranges", [])
                if value.get("repo", "").rstrip("/").removesuffix(".git") == repository
            ] if git else []
        )
        if ranges:
            matches.append({**item, "ranges": ranges})
        elif exact:
            matches.append(item)
    if not matches:
        raise RuntimeError("OSV advisory details do not match the queried package")
    return {**record, "affected": matches}
