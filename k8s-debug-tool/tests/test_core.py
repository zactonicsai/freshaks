"""Small unit tests that do not require a real Kubernetes cluster."""

from __future__ import annotations

import unittest

from k8s_doctor.clients import KubectlClient
from k8s_doctor.cli import _normalize_global_options
from k8s_doctor.diagnostics import DiagnosticsService
from k8s_doctor.models import CommandResult, Report
from k8s_doctor.runner import CommandRunner


class FakeRunner:
    def __init__(self):
        self.commands = []

    def run(self, command, **kwargs):
        self.commands.append(list(command))
        return CommandResult(command=list(command), returncode=0, stdout="ok")


class ClientTests(unittest.TestCase):
    def test_context_and_namespace_are_added(self):
        runner = FakeRunner()
        client = KubectlClient(runner, context="kind-kind", namespace="demo")
        client.run(["get", "pods"])
        self.assertEqual(
            runner.commands[0],
            ["kubectl", "--context", "kind-kind", "--namespace", "demo", "get", "pods"],
        )

    def test_non_namespaced_command_omits_namespace(self):
        runner = FakeRunner()
        client = KubectlClient(runner, context="kind-kind", namespace="demo")
        client.run(["get", "nodes"], namespaced=False)
        self.assertEqual(
            runner.commands[0],
            ["kubectl", "--context", "kind-kind", "get", "nodes"],
        )


class ModelTests(unittest.TestCase):
    def test_report_add(self):
        report = Report(title="Test")
        report.add("pods", "PASS", "all good")
        self.assertEqual(len(report.findings), 1)
        self.assertEqual(report.findings[0].check, "pods")


class RunnerTests(unittest.TestCase):
    def test_printable_quotes_arguments(self):
        text = CommandRunner.printable(["kubectl", "patch", "service", "demo", "-p", '{"a":"b c"}'])
        self.assertIn("kubectl", text)
        self.assertIn("b c", text)


class ReviewTests(unittest.TestCase):
    def test_review_finds_latest_and_privileged(self):
        report = Report(title="review")
        DiagnosticsService._review_pod_spec(
            report,
            {
                "containers": [
                    {
                        "name": "web",
                        "image": "nginx:latest",
                        "securityContext": {"privileged": True},
                    }
                ]
            },
        )
        statuses = {(f.check, f.status) for f in report.findings}
        self.assertIn(("image:web", "WARN"), statuses)
        self.assertIn(("security:web", "FAIL"), statuses)


class CliTests(unittest.TestCase):
    def test_global_output_option_can_follow_subcommand(self):
        normalized = _normalize_global_options(["review-file", "demo.yaml", "-o", "yaml"])
        self.assertEqual(normalized[:2], ["-o", "yaml"])
        self.assertEqual(normalized[2:], ["review-file", "demo.yaml"])


if __name__ == "__main__":
    unittest.main()
