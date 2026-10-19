#!/usr/bin/env python3
"""Run named suites and reject unregistered test entrypoints."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET


def registry(root):
    data = json.loads((root / "tests/suites.json").read_text())
    entries = data["tests"]
    discovered = {
        str(path.relative_to(root))
        for path in (root / "tests").rglob("test-*")
        if path.suffix in {".sh", ".py", ".ps1"}
    }
    registered = [entry["path"] for entry in entries]
    if len(set(registered)) != len(registered):
        raise ValueError("duplicate test registration")
    if set(registered) != discovered:
        raise ValueError(
            f"unregistered: {sorted(discovered - set(registered))}; "
            f"missing: {sorted(set(registered) - discovered)}"
        )
    for entry in entries:
        timeout = entry.get("timeout_seconds", 600)
        if not isinstance(timeout, int) or not 0 < timeout <= 1200:
            raise ValueError(f"invalid timeout: {entry}")
        if entry["kind"] == "suite":
            if entry["suite"] not in data["suites"]:
                raise ValueError(f"unknown suite: {entry}")
            if not entry.get("invocations") or not all(
                isinstance(argv, list) and all(isinstance(arg, str) for arg in argv)
                for argv in entry["invocations"]
            ):
                raise ValueError(f"missing argument vectors: {entry}")
        elif entry["kind"] in {"manual", "wrapper"}:
            if not entry.get("reason") or not entry.get("command"):
                raise ValueError(f"missing execution documentation: {entry}")
            if not entry.get("covered_by") or not all(
                (root / path).is_file() for path in entry["covered_by"]
            ):
                raise ValueError(f"missing caller or covered test: {entry}")
        else:
            raise ValueError(f"unknown test kind: {entry}")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", nargs="?")
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[2]
    )
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument(
        "--output", type=Path, help="directory for JSON, JUnit, and per-command logs"
    )
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        data = registry(root)
    except (ValueError, KeyError) as exc:
        parser.error(str(exc))
    if args.validate:
        print(f"Registry accounts for all {len(data['tests'])} test entrypoints")
        return
    if args.list and not args.suite:
        print("\n".join(data["suites"]))
        return
    if args.suite not in data["suites"]:
        parser.error(f"choose a suite: {', '.join(data['suites'])}")
    if not args.list and not Path("/.dockerenv").exists():
        parser.error("run suites inside Docker; use scripts/ci/docker-suite.sh")
    output = args.output or (
        Path(os.environ["CI_RESULTS_DIR"])
        if "CI_RESULTS_DIR" in os.environ
        else Path(tempfile.gettempdir()) / "dotfiles-ci" / args.suite
    )
    results = []

    def execute(name, argv, timeout=600):
        print("+ " + " ".join(argv), flush=True)
        if args.list:
            return
        output.mkdir(parents=True, exist_ok=True)
        logfile = output / f"{len(results) + 1:03d}.log"
        started = time.monotonic()
        with logfile.open("w") as stream:
            try:
                completed = subprocess.run(
                    argv,
                    cwd=root,
                    check=False,
                    timeout=timeout,
                    stdout=stream,
                    stderr=subprocess.STDOUT,
                )
                code = completed.returncode
            except subprocess.TimeoutExpired:
                code = 124
            except OSError as error:
                stream.write(str(error) + "\n")
                code = 127
        elapsed = round(time.monotonic() - started, 3)
        print(logfile.read_text(errors="replace"), end="", flush=True)
        status = "success" if code == 0 else "failure"
        print(f"[{status.upper()}] {name}: {elapsed:.3f}s (exit {code})", flush=True)
        results.append(
            {
                "name": name,
                "argv": argv,
                "status": status,
                "exit_code": code,
                "duration_seconds": elapsed,
                "log": logfile.name,
            }
        )

    for entry in data["tests"]:
        if entry.get("suite") != args.suite:
            continue
        for invocation in entry["invocations"]:
            executable = "python3" if entry["path"].endswith(".py") else "bash"
            argv = [executable, str(root / entry["path"])] + [
                arg.replace("{root}", str(root)) for arg in invocation
            ]
            execute(entry["path"], argv, entry.get("timeout_seconds", 600))
    for command in data["suites"][args.suite].get("checks", []):
        execute(" ".join(command), command)
    if not args.list:
        failed = [item for item in results if item["status"] != "success"]
        output.mkdir(parents=True, exist_ok=True)
        report = {
            "suite": args.suite,
            "status": "failure" if failed else "success",
            "duration_seconds": round(
                sum(item["duration_seconds"] for item in results), 3
            ),
            "results": results,
        }
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        xml = ET.Element(
            "testsuite",
            name=args.suite,
            tests=str(len(results)),
            failures=str(len(failed)),
            time=str(report["duration_seconds"]),
        )
        for item in results:
            case = ET.SubElement(
                xml, "testcase", name=item["name"], time=str(item["duration_seconds"])
            )
            if item["exit_code"] != 0:
                ET.SubElement(
                    case,
                    "failure",
                    message=f"exit {item['exit_code']}; see {item['log']}",
                )
        ET.ElementTree(xml).write(
            output / "junit.xml", encoding="unicode", xml_declaration=True
        )
        print(f"Suite report: {output / 'results.json'}", flush=True)
        if failed:
            raise SystemExit(
                "Failed commands: "
                + "; ".join(
                    f"{item['name']} (exit {item['exit_code']})" for item in failed
                )
            )


if __name__ == "__main__":
    main()
