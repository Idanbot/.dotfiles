#!/usr/bin/python3
"""Find scoped keyrings for active HashiCorp APT sources without rewriting them."""

import email.parser
import pathlib
import re
import shlex
import sys
import urllib.parse


def is_hashicorp(uri):
    return urllib.parse.urlsplit(uri).hostname == "apt.releases.hashicorp.com"


def keyrings(root):
    paths = set()
    files = [root / "sources.list", *sorted((root / "sources.list.d").glob("*.list"))]
    for file in files:
        if not file.exists():
            continue
        for line in file.read_text().splitlines():
            parts = shlex.split(line, comments=True)
            if not parts or parts[0] not in {"deb", "deb-src"}:
                continue
            offset, options = 1, {}
            if len(parts) > 1 and parts[1].startswith("["):
                end = next(i for i in range(1, len(parts)) if parts[i].endswith("]"))
                for option in " ".join(parts[1 : end + 1])[1:-1].split():
                    key, _, value = option.partition("=")
                    options[key.lower()] = value
                offset = end + 1
            if len(parts) > offset and is_hashicorp(parts[offset]):
                paths.update(options.get("signed-by", "").split(",") or [""])

    for file in sorted((root / "sources.list.d").glob("*.sources")):
        for stanza in re.split(r"\n\s*\n", file.read_text()):
            stanza = "\n".join(
                line for line in stanza.splitlines() if not line.startswith("#")
            )
            fields = email.parser.Parser().parsestr(stanza)
            if fields.get("Enabled", "yes").lower() == "no":
                continue
            if any(is_hashicorp(uri) for uri in fields.get("URIs", "").split()):
                paths.update(fields.get("Signed-By", "").split() or [""])

    allowed_parents = {
        pathlib.PurePosixPath("/usr/share/keyrings"),
        pathlib.PurePosixPath("/etc/apt/keyrings"),
    }
    for value in sorted(paths):
        path = pathlib.PurePosixPath(value)
        if (
            path.parent not in allowed_parents
            or "hashicorp" not in path.name.lower()
        ):
            raise ValueError(
                "HashiCorp source needs a dedicated Signed-By keyring under "
                "/usr/share/keyrings or /etc/apt/keyrings"
            )
    return sorted(paths)


if __name__ == "__main__":
    try:
        for keyring in keyrings(pathlib.Path(sys.argv[1])):
            print(keyring)
    except (ValueError, OSError, StopIteration) as error:
        print(f"Cannot refresh HashiCorp APT key: {error}", file=sys.stderr)
        sys.exit(1)
