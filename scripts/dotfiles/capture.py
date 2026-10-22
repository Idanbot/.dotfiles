"""Review-only capture of literal, typed settings, never arbitrary local text."""

import difflib
from pathlib import Path
import re
import shlex
import tomllib

from .local_review import ReviewError, read_local

TARGETS = {
    "zsh": (".zshrc", "dot_zshrc.tmpl"),
    "tmux": (".tmux.conf", "dot_tmux.conf.tmpl"),
    "starship": (".config/starship.toml", "dot_config/starship.toml"),
}
SETTINGS = {
    "zsh": {"HISTSIZE": (1, 10000000), "SAVEHIST": (1, 10000000)},
    "tmux": {
        "mouse": ("on", "off"),
        "history-limit": (1, 1000000),
        "status-interval": (1, 600),
    },
    "starship": {
        "command_timeout": (1, 30000),
        "scan_timeout": (1, 30000),
        "directory.truncation_length": (0, 100),
        "directory.truncate_to_repo": (True, False),
        "azure.disabled": (True, False),
        "status.disabled": (True, False),
        "time.disabled": (True, False),
        "jobs.disabled": (True, False),
    },
}


def typed(target, key, value):
    options = SETTINGS[target][key]
    if type(options[0]) is int:
        if type(value) is not int or not options[0] <= value <= options[1]:
            raise ReviewError("unsupported-setting-value")
        return str(value)
    if type(options[0]) is bool:
        if type(value) is not bool:
            raise ReviewError("unsupported-setting-value")
        return str(value).lower()
    if value not in options:
        raise ReviewError("unsupported-setting-value")
    return value


def shell_values(text):
    values = {}
    for line in text.splitlines():
        match = re.match(r"^(?:export[ \t]+)?(HISTSIZE|SAVEHIST)[ \t]*=(.*)$", line)
        if not match:
            continue
        tokens = shlex.split(match[2], comments=True)
        if len(tokens) != 1 or not re.fullmatch(r"[0-9]{1,8}", tokens[0]):
            raise ReviewError("computed-shell-setting-not-supported")
        values[match[1]] = int(tokens[0])
    return values


def tmux_values(text):
    values = {}
    for line in text.splitlines():
        # Ignore unrelated commands without trying to interpret or execute them.
        if not re.match(
            r"^(?:set|set-option)[ \t]+-g[ \t]+(?:mouse|history-limit|status-interval)[ \t]",
            line,
        ):
            continue
        tokens = shlex.split(line, comments=True)
        if len(tokens) != 4:
            raise ReviewError("computed-tmux-setting-not-supported")
        key, value = tokens[2:]
        if key != "mouse":
            if not re.fullmatch(r"[0-9]{1,8}", value):
                raise ReviewError("computed-tmux-setting-not-supported")
            value = int(value)
        values[key] = value
    return values


def toml_values(text):
    document = tomllib.loads(text)
    values = {}
    for key in SETTINGS["starship"]:
        value = document
        for name in key.split("."):
            if not isinstance(value, dict) or name not in value:
                break
            value = value[name]
        else:
            values[key] = value
    return values


def template_lines(target, lines):
    section = ""
    multiline = None
    locations = {}
    for index, line in enumerate(lines):
        if target == "starship":
            if multiline:
                if line.count(multiline) % 2:
                    multiline = None
                continue
            for delimiter in ('"""', "'''"):
                if line.count(delimiter) % 2:
                    multiline = delimiter
                    break
            if multiline:
                continue
            heading = re.fullmatch(r"\[([a-z_.]+)\]\s*", line)
            if heading:
                section = heading[1]
                continue
            match = re.fullmatch(
                r"([a-z_]+)([ \t]*=[ \t]*)([0-9]+|true|false)[ \t]*\n?", line
            )
            if match:
                key = f"{section}.{match[1]}" if section else match[1]
                prefix = match[1] + match[2]
        elif target == "zsh":
            match = re.fullmatch(
                r"((?:export[ \t]+)?)(HISTSIZE|SAVEHIST)=([0-9]+)[ \t]*\n?", line
            )
            if match:
                key, prefix = match[2], match[1] + match[2] + "="
        else:
            match = re.fullmatch(
                r"(set(?:-option)?[ \t]+-g[ \t]+)(mouse|history-limit|status-interval)([ \t]+)([0-9]+|on|off)[ \t]*\n?",
                line,
            )
            if match:
                key, prefix = match[2], match[1] + match[2] + match[3]
        if match and key in SETTINGS[target]:
            if key in locations:
                raise ReviewError("ambiguous-template-setting")
            locations[key] = index, prefix
    return locations


def capture(root, target):
    if target not in TARGETS:
        raise ReviewError("unsupported-capture-target")
    local, relative = TARGETS[target]
    document = read_local(Path.home() / local, 1024 * 1024)
    values = {"zsh": shell_values, "tmux": tmux_values, "starship": toml_values}[
        target
    ](document)
    # Construct new lines from validated scalars, never from local config text.
    values = {key: typed(target, key, value) for key, value in values.items()}
    original = read_local(root / relative, 1024 * 1024).splitlines(keepends=True)
    updated = list(original)
    locations = template_lines(target, original)
    for key, value in values.items():
        if key not in locations:
            raise ReviewError("unsupported-template-setting")
        index, prefix = locations[key]
        updated[index] = prefix + value + "\n"
    # Zero context prevents neighboring comments, aliases, paths, and commands
    # from being exported even when the source checkout has local customizations.
    return "".join(
        difflib.unified_diff(
            original, updated, fromfile="a/" + relative, tofile="b/" + relative, n=0
        )
    )
