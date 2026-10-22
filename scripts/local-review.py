#!/usr/bin/python3
"""Explicit local diagnostics and allowlisted exports; offline unless --online."""

import argparse
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
try:
    from dotfiles import local_review as review
    from dotfiles.installed_audit import DEFAULT_MAX_AGE_DAYS
except ImportError:
    raise SystemExit("local-review: missing-bootstrap-python-dependencies") from None


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, "local-review: invalid-arguments; use --help\n")


def main():
    parser = Parser(description=__doc__)
    parser.add_argument(
        "--source", type=Path, default=Path(__file__).resolve().parent.parent
    )
    commands = parser.add_subparsers(dest="command", required=True, parser_class=Parser)
    check = commands.add_parser(
        "check", help="Offline syntax and safety checks; diagnostic codes only"
    )
    check.add_argument("--json", action="store_true")
    check.add_argument("--output", type=Path)
    receipt = commands.add_parser(
        "receipt", help="Create or compare an allowlisted software receipt"
    )
    operations = receipt.add_subparsers(
        dest="operation", required=True, parser_class=Parser
    )
    create = operations.add_parser("create")
    create.add_argument("--output", type=Path)
    compare = operations.add_parser("compare")
    compare.add_argument("before", type=Path)
    compare.add_argument("after", type=Path)
    compare.add_argument("--output", type=Path)
    capture = commands.add_parser(
        "capture",
        help="Export only allowlisted literal settings as a review-only patch",
    )
    capture.add_argument("target", nargs="?")
    capture.add_argument("--list", action="store_true")
    capture.add_argument("--output", type=Path)
    audit = commands.add_parser(
        "audit",
        help="Audit observed versions; --online explicitly sends tool versions to OSV",
    )
    audit.add_argument("--installed", action="store_true", required=True)
    audit.add_argument("--receipt", type=Path)
    audit.add_argument("--online", action="store_true")
    audit.add_argument("--advisories", type=Path)
    audit.add_argument(
        "--max-age-days",
        type=int,
        default=DEFAULT_MAX_AGE_DAYS,
        help=f"advisory-cache lifetime in UTC days (0-365; default: {DEFAULT_MAX_AGE_DAYS})",
    )
    audit.add_argument("--cache-output", type=Path)
    audit.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.source.resolve()
    if args.command == "capture":
        from dotfiles import capture

        if args.list:
            print(
                json.dumps(
                    {name: sorted(keys) for name, keys in capture.SETTINGS.items()},
                    indent=2,
                )
            )
            return 0
        if not args.output or not args.target:
            parser.error("capture requires target and output")
        review.write_private(args.output, capture.capture(root, args.target))
        print("local-review: private-capture-written; review before applying")
        return 0
    if args.command == "audit":
        from dotfiles import installed_audit

        if args.cache_output and not args.online:
            parser.error("cache output requires online")
        observed = (
            review.read_json(args.receipt) if args.receipt else review.receipt(root)
        )
        cache = review.read_json(args.advisories) if args.advisories else None
        data, cached = installed_audit.audit(
            root,
            observed,
            online=args.online,
            cache=cache,
            max_age_days=args.max_age_days,
        )
        if args.cache_output:
            review.write_private(
                args.cache_output, json.dumps(cached, sort_keys=True, indent=2) + "\n"
            )
        code = 0
    elif args.command == "check":
        data = review.check_local(root)
        code = int(any(item["status"] == "attention" for item in data["checks"]))
    elif args.operation == "create":
        data = review.receipt(root)
        review.validate_receipt(data, root)
        code = 0
    else:
        data = review.compare_receipts(
            review.read_json(args.before), review.read_json(args.after), root
        )
        code = 0
    text = json.dumps(data, sort_keys=True, indent=2) + "\n"
    if args.output:
        review.write_private(args.output, text)
        print("local-review: private-output-written")
    elif args.command == "check" and not args.json:
        for check in data["checks"]:
            print(f"{check['status']:12} {check['id']}")
    else:
        print(text, end="")
    return code


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        RuntimeError,
        ImportError,
    ):
        raise SystemExit(
            "local-review: invalid-or-unavailable-data; no raw diagnostics emitted"
        ) from None
