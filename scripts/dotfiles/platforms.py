"""Shared Python labels for supported Ubuntu hosts."""

SUPPORTED_UBUNTU = frozenset({"ubuntu-24.04", "ubuntu-26.04"})


def ubuntu_label(os_release):
    label = f"{os_release.get('ID')}-{os_release.get('VERSION_ID')}"
    return label if label in SUPPORTED_UBUNTU else "unsupported"
