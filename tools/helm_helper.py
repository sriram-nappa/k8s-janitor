#!/usr/bin/env python3
"""Utility CLI to manage the namespace-janitor Helm chart for local testing."""
import argparse
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CHART_PATH = REPO_ROOT / "chart" / "namespace-janitor"
DEFAULT_RELEASE = "namespace-janitor"
DEFAULT_NAMESPACE = "janitor"

SAFE_OVERRIDES = [
    "--set", "alertMode=none",
    "--set", "dryRun=true",
    "--set", "maxNamespaceAgeHours=0",
    "--set", "alertSecret.create=true",
    "--set", "alertSecret.data.slack-webhook-url=https://hooks.slack.com/services/dummy/dummy/dummy",
]


def run(cmd):
    print("$", " ".join(cmd))
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as exc:
        sys.exit(exc.returncode)


def install(args):
    cmd = [
        "helm", "upgrade", "--install", args.release, str(CHART_PATH),
        "--namespace", args.namespace,
    ]
    if args.create_namespace:
        cmd.append("--create-namespace")
    if args.safe:
        cmd.extend(SAFE_OVERRIDES)
    if args.values:
        cmd.extend(["-f", args.values])
    if args.extra:
        cmd.extend(args.extra)
    run(cmd)


def uninstall(args):
    cmd = ["helm", "uninstall", args.release, "-n", args.namespace]
    run(cmd)


def debug(args):
    release = args.release
    namespace = args.namespace
    cronjob = args.cronjob or f"{release}-namespace-janitor"
    run(["kubectl", "-n", namespace, "get", "pods"])
    run(["kubectl", "-n", namespace, "logs", f"cronjob/{cronjob}"])


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    install_parser = sub.add_parser("install", help="Install or upgrade the chart")
    install_parser.add_argument("--release", default=DEFAULT_RELEASE)
    install_parser.add_argument("--namespace", default=DEFAULT_NAMESPACE)
    install_parser.add_argument("--create-namespace", action="store_true")
    install_parser.add_argument("--values")
    install_parser.add_argument("--safe", action="store_true", help="Apply dry-run friendly overrides")
    install_parser.add_argument("extra", nargs=argparse.REMAINDER, help="Additional args passed to helm upgrade --install")
    install_parser.set_defaults(func=install)

    uninstall_parser = sub.add_parser("uninstall", help="Remove the release")
    uninstall_parser.add_argument("--release", default=DEFAULT_RELEASE)
    uninstall_parser.add_argument("--namespace", default=DEFAULT_NAMESPACE)
    uninstall_parser.set_defaults(func=uninstall)

    debug_parser = sub.add_parser("debug", help="Show pod status/logs")
    debug_parser.add_argument("--release", default=DEFAULT_RELEASE)
    debug_parser.add_argument("--namespace", default=DEFAULT_NAMESPACE)
    debug_parser.add_argument("--cronjob")
    debug_parser.set_defaults(func=debug)

    return parser.parse_args()


def main():
    args = parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
