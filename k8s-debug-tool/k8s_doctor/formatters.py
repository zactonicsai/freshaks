"""Output formatters for human-readable, JSON, YAML, and standalone HTML reports."""

from __future__ import annotations

import html
import json
from dataclasses import asdict
from typing import Any

import yaml
from rich.console import Console
from rich.table import Table

from .models import CommandResult, Report
from .runner import CommandRunner


STATUS_SYMBOLS = {
    "PASS": "✓",
    "WARN": "!",
    "FAIL": "✗",
    "INFO": "•",
}


def _plain_value(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return yaml.safe_dump(value, sort_keys=False).rstrip()
    return str(value)


def report_to_dict(report: Report) -> dict[str, Any]:
    return asdict(report)


def render_report(report: Report, output_format: str) -> str:
    """Return a report as text for non-interactive formats.

    Human output is rendered separately with Rich so terminals get clean tables.
    """

    data = report_to_dict(report)
    if output_format == "json":
        return json.dumps(data, indent=2)
    if output_format == "yaml":
        return yaml.safe_dump(data, sort_keys=False)
    if output_format == "html":
        rows = []
        for finding in report.findings:
            details = html.escape(_plain_value(finding.details))
            recommendation = html.escape(finding.recommendation or "")
            command = html.escape(finding.command or "")
            rows.append(
                "<tr>"
                f"<td>{html.escape(finding.status)}</td>"
                f"<td>{html.escape(finding.check)}</td>"
                f"<td>{html.escape(finding.summary)}</td>"
                f"<td><pre>{details}</pre></td>"
                f"<td>{recommendation}</td>"
                f"<td><code>{command}</code></td>"
                "</tr>"
            )
        return f"""<!doctype html>
<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>{html.escape(report.title)}</title>
<style>
body{{font-family:Arial,sans-serif;margin:2rem;color:#161616;background:#fff}}h1{{color:#0f3d75}}table{{border-collapse:collapse;width:100%}}th,td{{border:1px solid #d0d7de;padding:.55rem;vertical-align:top;text-align:left}}th{{background:#eef4fb}}pre{{white-space:pre-wrap;margin:0}}code{{white-space:pre-wrap}}.meta{{color:#525252}}
</style></head><body>
<h1>{html.escape(report.title)}</h1>
<p class=\"meta\">Context: {html.escape(report.context or 'default')} &nbsp; Namespace: {html.escape(report.namespace or 'default/current')}</p>
<table><thead><tr><th>Status</th><th>Check</th><th>Summary</th><th>Details</th><th>Recommendation</th><th>Command</th></tr></thead>
<tbody>{''.join(rows)}</tbody></table></body></html>"""
    raise ValueError(f"Unsupported output format: {output_format}")


def print_human_report(report: Report) -> None:
    """Print a compact table, then expanded details below it."""

    console = Console()
    console.print(f"[bold blue]{report.title}[/bold blue]")
    console.print(f"Context: {report.context or 'default'} | Namespace: {report.namespace or 'default/current'}")
    table = Table(show_header=True, header_style="bold")
    table.add_column("Status", width=8)
    table.add_column("Check", width=24)
    table.add_column("Summary")
    for finding in report.findings:
        symbol = STATUS_SYMBOLS.get(finding.status, "•")
        table.add_row(f"{symbol} {finding.status}", finding.check, finding.summary)
    console.print(table)

    for finding in report.findings:
        if finding.details is None and not finding.recommendation and not finding.command:
            continue
        console.print(f"\n[bold]{finding.check}[/bold]")
        if finding.details is not None:
            console.print(_plain_value(finding.details))
        if finding.recommendation:
            console.print(f"Recommendation: {finding.recommendation}")
        if finding.command:
            console.print(f"Command: {finding.command}")


def command_result_to_report(title: str, result: CommandResult, *, context: str | None, namespace: str | None) -> Report:
    """Wrap arbitrary kubectl/helm output so every CLI command supports all formats."""

    report = Report(title=title, context=context, namespace=namespace)
    report.add(
        check="command",
        status="PASS" if result.ok else "FAIL",
        summary=f"Command exited with code {result.returncode}",
        details={"stdout": result.stdout, "stderr": result.stderr, "duration_seconds": round(result.duration_seconds, 3)},
        command=CommandRunner.printable(result.command),
    )
    return report
