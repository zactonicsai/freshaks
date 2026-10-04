"""Command-line interface for k8s-doctor.

The CLI uses Python's standard ``argparse`` module so every option automatically
appears in ``--help`` and shell scripts receive predictable exit codes.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .clients import HelmClient, KubectlClient
from .diagnostics import DiagnosticsService
from .formatters import command_result_to_report, print_human_report, render_report
from .models import Report
from .runner import CommandError, CommandRunner


OUTPUT_CHOICES = ("human", "json", "yaml", "html")


def add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--context", help="Kubernetes context to use instead of the current context")
    parser.add_argument("-n", "--namespace", help="Kubernetes namespace")
    parser.add_argument("-o", "--output", choices=OUTPUT_CHOICES, default="human", help="Output format")
    parser.add_argument("--output-file", help="Write rendered output to a file instead of stdout")
    parser.add_argument("--timeout", type=int, default=30, help="External command timeout in seconds (default: 30)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="k8s-doctor",
        description="Inspect, debug, review, and safely operate Kubernetes clusters using installed kubectl and helm.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    add_common(parser)
    sub = parser.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor", help="Run common cluster troubleshooting checks")
    doctor.add_argument("-A", "--all-namespaces", action="store_true", help="Check namespaced resources across all namespaces")

    network = sub.add_parser("network", help="Run focused Service/endpoints/Ingress/NetworkPolicy/DNS checks")
    network.add_argument("-A", "--all-namespaces", action="store_true")

    sub.add_parser("auth", help="Show current Kubernetes RBAC permissions with kubectl auth can-i --list")

    pod = sub.add_parser("pod", help="Create a focused pod debug report")
    pod.add_argument("name")
    pod.add_argument("--show-secret-data", action="store_true", help="Include decoded referenced secret values (sensitive)")

    logs = sub.add_parser("logs", help="Read pod logs")
    logs.add_argument("pod")
    logs.add_argument("-c", "--container")
    logs.add_argument("--previous", action="store_true")
    logs.add_argument("--tail", type=int, default=200)
    logs.add_argument("--since", help="kubectl duration such as 10m or 2h")

    resource = sub.add_parser("resource", help="Get or describe a Kubernetes resource")
    resource.add_argument("action", choices=("get", "describe"))
    resource.add_argument("type")
    resource.add_argument("name", nargs="?")
    resource.add_argument("-A", "--all-namespaces", action="store_true")

    events = sub.add_parser("events", help="Show cluster/namespace events")
    events.add_argument("-A", "--all-namespaces", action="store_true")

    secret = sub.add_parser("secret", help="Review a Secret safely; values are redacted by default")
    secret.add_argument("name")
    secret.add_argument("--show-secret-data", action="store_true", help="Decode and print secret values (sensitive)")

    review = sub.add_parser("review", help="Review a live workload configuration for common issues")
    review.add_argument("type", help="pod, deployment, statefulset, daemonset, job, etc.")
    review.add_argument("name")

    review_file = sub.add_parser("review-file", help="Review a local Kubernetes YAML file without changing the cluster")
    review_file.add_argument("file")

    apply_cmd = sub.add_parser("apply", help="Validate/apply a manifest; dry-run by default")
    apply_cmd.add_argument("file")
    apply_cmd.add_argument("--execute", action="store_true", help="Actually apply the manifest")

    delete = sub.add_parser("delete", help="Delete a resource; plan-only by default")
    delete.add_argument("type")
    delete.add_argument("name")
    delete.add_argument("--execute", action="store_true")
    delete.add_argument("--yes", action="store_true", help="Required with --execute for destructive deletion")

    patch = sub.add_parser("patch", help="Patch a resource; server-side dry-run by default")
    patch.add_argument("type")
    patch.add_argument("name")
    patch.add_argument("patch", help="Patch JSON/YAML string")
    patch.add_argument("--patch-type", choices=("merge", "json", "strategic"), default="strategic")
    patch.add_argument("--execute", action="store_true")

    restart = sub.add_parser("restart", help="Rollout restart a workload; plan-only by default")
    restart.add_argument("type", choices=("deployment", "statefulset", "daemonset"))
    restart.add_argument("name")
    restart.add_argument("--execute", action="store_true")

    scale = sub.add_parser("scale", help="Scale a workload; plan-only by default")
    scale.add_argument("type", choices=("deployment", "statefulset", "replicaset"))
    scale.add_argument("name")
    scale.add_argument("replicas", type=int)
    scale.add_argument("--execute", action="store_true")

    image = sub.add_parser("set-image", help="Update a workload image; plan-only by default")
    image.add_argument("type", choices=("deployment", "statefulset", "daemonset"))
    image.add_argument("name")
    image.add_argument("container")
    image.add_argument("image")
    image.add_argument("--execute", action="store_true")

    helm = sub.add_parser("helm", help="Helm release/chart operations")
    helm_sub = helm.add_subparsers(dest="helm_command", required=True)

    helm_list = helm_sub.add_parser("list")
    helm_list.add_argument("-A", "--all-namespaces", action="store_true")

    for name in ("status", "values", "manifest", "history"):
        p = helm_sub.add_parser(name)
        p.add_argument("release")
        if name == "values":
            p.add_argument("--all-values", action="store_true")

    lint = helm_sub.add_parser("lint")
    lint.add_argument("chart")
    lint.add_argument("-f", "--values", action="append", default=[])

    template = helm_sub.add_parser("template")
    template.add_argument("release")
    template.add_argument("chart")
    template.add_argument("-f", "--values", action="append", default=[])

    for name in ("install", "upgrade"):
        p = helm_sub.add_parser(name)
        p.add_argument("release")
        p.add_argument("chart")
        p.add_argument("-f", "--values", action="append", default=[])
        p.add_argument("--set", dest="set_values", action="append", default=[])
        if name == "upgrade":
            p.add_argument("--install-if-missing", action="store_true")
        p.add_argument("--execute", action="store_true")

    uninstall = helm_sub.add_parser("uninstall")
    uninstall.add_argument("release")
    uninstall.add_argument("--execute", action="store_true")
    uninstall.add_argument("--yes", action="store_true")

    rollback = helm_sub.add_parser("rollback")
    rollback.add_argument("release")
    rollback.add_argument("revision", type=int)
    rollback.add_argument("--execute", action="store_true")

    return parser


def emit(report: Report, output_format: str, output_file: str | None) -> None:
    if output_format == "human" and not output_file:
        print_human_report(report)
        return
    if output_format == "human":
        # Files should be plain text rather than ANSI terminal escape sequences.
        lines = [report.title, f"Context: {report.context or 'default'}", f"Namespace: {report.namespace or 'default/current'}", ""]
        for f in report.findings:
            lines.append(f"[{f.status}] {f.check}: {f.summary}")
            if f.details is not None:
                lines.append(str(f.details))
            if f.recommendation:
                lines.append(f"Recommendation: {f.recommendation}")
            if f.command:
                lines.append(f"Command: {f.command}")
            lines.append("")
        rendered = "\n".join(lines)
    else:
        rendered = render_report(report, output_format)
    if output_file:
        Path(output_file).write_text(rendered + ("\n" if not rendered.endswith("\n") else ""), encoding="utf-8")
        print(f"Wrote {output_format} output to {output_file}")
    else:
        print(rendered)


def result_report(title: str, result, args) -> Report:
    return command_result_to_report(title, result, context=args.context, namespace=args.namespace)


def run_command(args: argparse.Namespace) -> Report:
    runner = CommandRunner(timeout=args.timeout)
    kubectl = KubectlClient(runner, context=args.context, namespace=args.namespace)
    helm = HelmClient(runner, context=args.context, namespace=args.namespace)
    diagnostics = DiagnosticsService(kubectl, helm)

    if args.command == "doctor":
        return diagnostics.full_report(all_namespaces=args.all_namespaces)
    if args.command == "network":
        return diagnostics.network_report(all_namespaces=args.all_namespaces)
    if args.command == "auth":
        return diagnostics.auth_report()
    if args.command == "pod":
        return diagnostics.pod_report(args.name, show_secret_data=args.show_secret_data)
    if args.command == "secret":
        return diagnostics.secret_report(args.name, show_data=args.show_secret_data)
    if args.command == "review":
        return diagnostics.config_review(args.type, args.name)
    if args.command == "review-file":
        return diagnostics.file_review(args.file)
    if args.command == "logs":
        return result_report(f"Logs: {args.pod}", kubectl.logs(args.pod, container=args.container, previous=args.previous, tail=args.tail, since=args.since), args)
    if args.command == "events":
        return result_report("Kubernetes Events", kubectl.events(all_namespaces=args.all_namespaces), args)
    if args.command == "resource":
        if args.action == "describe":
            if not args.name:
                raise ValueError("resource describe requires NAME")
            result = kubectl.describe(args.type, args.name)
        else:
            get_args = ["get", args.type]
            if args.name:
                get_args.append(args.name)
            if args.all_namespaces:
                get_args.append("--all-namespaces")
            get_args += ["-o", "wide"]
            result = kubectl.run(get_args, namespaced=not args.all_namespaces)
        return result_report(f"Resource {args.action}: {args.type}", result, args)
    if args.command == "apply":
        return result_report(f"Apply manifest: {args.file}", kubectl.apply(args.file, execute=args.execute), args)
    if args.command == "delete":
        if args.execute and not args.yes:
            raise ValueError("Destructive delete requires both --execute and --yes")
        return result_report(f"Delete {args.type}/{args.name}", kubectl.delete(args.type, args.name, execute=args.execute), args)
    if args.command == "patch":
        return result_report(f"Patch {args.type}/{args.name}", kubectl.patch(args.type, args.name, args.patch, args.patch_type, execute=args.execute), args)
    if args.command == "restart":
        return result_report(f"Restart {args.type}/{args.name}", kubectl.rollout_restart(args.type, args.name, execute=args.execute), args)
    if args.command == "scale":
        if args.replicas < 0:
            raise ValueError("replicas must be zero or greater")
        return result_report(f"Scale {args.type}/{args.name}", kubectl.scale(args.type, args.name, args.replicas, execute=args.execute), args)
    if args.command == "set-image":
        return result_report(f"Set image {args.type}/{args.name}", kubectl.set_image(args.type, args.name, args.container, args.image, execute=args.execute), args)
    if args.command == "helm":
        hc = args.helm_command
        if hc == "list":
            result = helm.list(all_namespaces=args.all_namespaces)
        elif hc == "status":
            result = helm.status(args.release)
        elif hc == "values":
            result = helm.values(args.release, all_values=args.all_values)
        elif hc == "manifest":
            result = helm.manifest(args.release)
        elif hc == "history":
            result = helm.history(args.release)
        elif hc == "lint":
            result = helm.lint(args.chart, args.values)
        elif hc == "template":
            result = helm.template(args.release, args.chart, args.values)
        elif hc == "install":
            result = helm.install(args.release, args.chart, values_files=args.values, set_values=args.set_values, execute=args.execute)
        elif hc == "upgrade":
            result = helm.upgrade(args.release, args.chart, values_files=args.values, set_values=args.set_values, install_if_missing=args.install_if_missing, execute=args.execute)
        elif hc == "uninstall":
            if args.execute and not args.yes:
                raise ValueError("Helm uninstall requires both --execute and --yes")
            result = helm.uninstall(args.release, execute=args.execute)
        elif hc == "rollback":
            if args.revision < 1:
                raise ValueError("revision must be 1 or greater")
            result = helm.rollback(args.release, args.revision, execute=args.execute)
        else:
            raise ValueError(f"Unknown helm command: {hc}")
        return result_report(f"Helm {hc}", result, args)
    raise ValueError(f"Unknown command: {args.command}")



def _normalize_global_options(argv: list[str]) -> list[str]:
    """Allow global options before or after subcommands.

    ``argparse`` normally expects options defined on the root parser before the
    selected subcommand. Operators often type ``doctor -o json`` instead of
    ``-o json doctor``. This small preprocessor moves known root options to the
    front while leaving command-specific arguments in their original order.
    """

    value_options = {"--context", "-n", "--namespace", "-o", "--output", "--output-file", "--timeout"}
    prefixes = ("--context=", "--namespace=", "--output=", "--output-file=", "--timeout=")
    globals_: list[str] = []
    rest: list[str] = []
    i = 0
    while i < len(argv):
        token = argv[i]
        if token in value_options:
            globals_.append(token)
            if i + 1 < len(argv):
                globals_.append(argv[i + 1])
                i += 2
                continue
        elif token.startswith(prefixes):
            globals_.append(token)
            i += 1
            continue
        rest.append(token)
        i += 1
    return globals_ + rest


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    raw_argv = list(argv) if argv is not None else sys.argv[1:]
    args = parser.parse_args(_normalize_global_options(raw_argv))
    try:
        report = run_command(args)
        emit(report, args.output, args.output_file)
        return 0 if all(f.status != "FAIL" for f in report.findings) else 2
    except (CommandError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
