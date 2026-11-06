#!/usr/bin/env python3
"""Private advisory readiness: no provider process executes without explicit opt-in."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess


CAPABILITIES = {
    "github": ("gh", ".config/gh/hosts.yml", ["api", "user", "--silent"], "gh auth login"),
    "aws": ("aws", ".aws/config", ["sts", "get-caller-identity", "--output", "json"], "aws sso login --profile PROFILE"),
    "gcloud": ("gcloud", ".config/gcloud", ["projects", "list", "--limit=1", "--format=none", "--quiet"], "gcloud auth login"),
    "azure": ("az", ".azure/azureProfile.json", ["group", "list", "--output", "none"], "az login"),
    "kubernetes": ("kubectl", ".kube/config", ["auth", "can-i", "get", "pods", "--request-timeout=8s"], "kubectl config use-context CONTEXT"),
    "ssh": ("ssh", ".ssh/config", None, "ssh -G HOST_ALIAS"),
    "cloudflare": ("cloudflared", ".ssh/config", None, "cloudflared access login https://HOST"),
    **{name: (name, None, None, f"{name} --help") for name in ("codex", "claude", "agy", "opencode", "omp")},
}


def run_probe(args, *, env, timeout):
    process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True, env=env)
    try:
        output, error = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=1)
        raise
    return subprocess.CompletedProcess(args, process.returncode, output, error)


def inspect(verify=False, home=None, timeout=10):
    home = Path(home or Path.home())
    results = []
    for capability, (binary, config, probe, remedy) in CAPABILITIES.items():
        installed = shutil.which(binary) is not None
        config_home = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
        config_path = {
            "github": Path(os.environ.get("GH_CONFIG_DIR", config_home / "gh")) / "hosts.yml",
            "aws": Path(os.environ.get("AWS_CONFIG_FILE", home / ".aws/config")),
            "gcloud": Path(os.environ.get("CLOUDSDK_CONFIG", config_home / "gcloud")),
            "azure": Path(os.environ.get("AZURE_CONFIG_DIR", home / ".azure")) / "azureProfile.json",
        }.get(capability, home / (config or "."))
        configured = installed and config is not None and config_path.exists()
        if capability == "kubernetes" and installed:
            configured = any(Path(path).exists() for path in os.environ.get(
                "KUBECONFIG", str(home / ".kube/config")).split(os.pathsep) if path)
        item = {"capability": capability, "installed": installed, "configured": configured,
                "state": "configured" if configured else "installed" if installed else "unavailable",
                "access": "unverified", "reason": "not-probed", "next_step": remedy}
        if verify and installed:
            item["state"] = "access-unverified"
            if probe is not None:
                env = {**os.environ, "GH_PROMPT_DISABLED": "1", "AWS_PAGER": "",
                       "AWS_CLI_AUTO_PROMPT": "off", "CLOUDSDK_CORE_DISABLE_PROMPTS": "1"}
                try:
                    completed = run_probe([binary, *probe], timeout=timeout, env=env)
                    # Native output may contain tokens, identifiers, or paths: classify,
                    # then discard it. Never include arbitrary output in reports.
                    error = completed.stderr.decode("utf-8", errors="replace").lower()
                    if completed.returncode == 0:
                        item.update(state="access-verified", access="verified", reason="probe-succeeded")
                    else:
                        reason = "expired" if "expired" in error else "denied" if any(
                            word in error for word in ("denied", "forbidden", "unauthorized")) else "unknown"
                        item["reason"] = reason
                except subprocess.TimeoutExpired:
                    item["reason"] = "timeout"
                except OSError:
                    item["reason"] = "unavailable"
        results.append(item)
    return {"schema_version": 1, "advisory": True, "network_requested": verify,
            "scope": "Configured means local file presence only; verified means only the specific read-only probe succeeded, not all permissions or agent authentication.",
            "results": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-access", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    report = inspect(args.verify_access)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print("Capability Readiness (advisory)")
        for item in report["results"]:
            print(f"  {item['capability']}: {item['state']}; access {item['access']} ({item['reason']})")
            if item["access"] != "verified":
                print(f"    Next: {item['next_step']}")
        print(report["scope"])


if __name__ == "__main__":
    main()
