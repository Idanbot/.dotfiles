"""Shared capabilities for explicit takeover, not ordinary owned upgrades."""

import os
from pathlib import Path
import sys


BINARY_BACKENDS = {"direct", "dotfiles-binary", "dotfiles-runtime"}
MANUAL_BINARIES = {
    "java",
    "javac",
    "jar",
    "javadoc",
    "jshell",
    "rustup",
    "rustc",
    "rustdoc",
    "rustfmt",
    "cargo",
    "clippy",
    "npm",
    "npx",
    "corepack",
    "kitty",
}
MANUAL_TOOLS = {"languages.java", "languages.rust", "languages.cargo", "languages.npm"}


def replacement_blocker(binary, owner="direct", ident=""):
    if (
        owner not in BINARY_BACKENDS
        or binary in MANUAL_BINARIES
        or ident in MANUAL_TOOLS
    ):
        return (
            "named takeover is unsupported for this backend; manual migration required"
        )
    return None


if __name__ == "__main__":
    binary = sys.argv[1]
    owner = sys.argv[2] if len(sys.argv) > 2 else "auto"
    if owner == "auto":
        from .metadata import load_metadata

        source = Path(__file__).resolve().parents[2]
        metadata = load_metadata(
            Path(
                os.environ.get(
                    "DOTFILES_PACKAGES_META_FILE", source / "packages.meta.yaml"
                )
            )
        )
        owner = next(
            (
                entry.get("owner", "manual")
                for tools in metadata.values()
                for name, entry in tools.items()
                if entry.get("binary", name) == binary
            ),
            "direct",
        )
    reason = replacement_blocker(binary, owner)
    if reason:
        sys.exit(reason)
