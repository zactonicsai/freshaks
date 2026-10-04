"""Thin wrappers around kubectl and helm.

These classes build command argument lists only. The actual process handling is
centralized in :mod:`k8s_doctor.runner`, which improves safety and testability.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable

import yaml

from .models import CommandResult
from .runner import CommandRunner


class KubectlClient:
    """Build and run kubectl commands for one context/namespace."""

    def __init__(
        self,
        runner: CommandRunner,
        *,
        context: str | None = None,
        namespace: str | None = None,
    ) -> None:
        self.runner = runner
        self.context = context
        self.namespace = namespace

    def _base(self, *, namespaced: bool = True) -> list[str]:
        command = ["kubectl"]
        if self.context:
            command += ["--context", self.context]
        if namespaced and self.namespace:
            command += ["--namespace", self.namespace]
        return command

    def run(self, args: Iterable[str], *, namespaced: bool = True, timeout: int | None = None) -> CommandResult:
        return self.runner.run(self._base(namespaced=namespaced) + list(args), timeout=timeout)

    def current_context(self) -> CommandResult:
        return self.run(["config", "current-context"], namespaced=False)

    def version(self) -> CommandResult:
        return self.run(["version", "-o", "json"], namespaced=False)

    def cluster_info(self) -> CommandResult:
        return self.run(["cluster-info"], namespaced=False)

    def get_json(self, resource: str, name: str | None = None, *, all_namespaces: bool = False) -> tuple[CommandResult, Any | None]:
        args = ["get", resource]
        if name:
            args.append(name)
        if all_namespaces:
            args.append("--all-namespaces")
        args += ["-o", "json"]
        result = self.run(args, namespaced=not all_namespaces)
        if not result.ok or not result.stdout:
            return result, None
        try:
            return result, json.loads(result.stdout)
        except json.JSONDecodeError:
            return result, None

    def get_yaml(self, resource: str, name: str) -> tuple[CommandResult, Any | None]:
        result = self.run(["get", resource, name, "-o", "yaml"])
        if not result.ok or not result.stdout:
            return result, None
        try:
            return result, yaml.safe_load(result.stdout)
        except yaml.YAMLError:
            return result, None

    def describe(self, resource: str, name: str) -> CommandResult:
        return self.run(["describe", resource, name])

    def events(self, *, all_namespaces: bool = False) -> CommandResult:
        args = ["get", "events"]
        if all_namespaces:
            args.append("--all-namespaces")
        args += ["--sort-by=.lastTimestamp"]
        return self.run(args, namespaced=not all_namespaces)

    def logs(
        self,
        pod: str,
        *,
        container: str | None = None,
        previous: bool = False,
        tail: int = 200,
        since: str | None = None,
    ) -> CommandResult:
        args = ["logs", pod, f"--tail={tail}"]
        if container:
            args += ["-c", container]
        if previous:
            args.append("--previous")
        if since:
            args += ["--since", since]
        return self.run(args)

    def top(self, resource: str) -> CommandResult:
        return self.run(["top", resource])

    def auth_can_i(self) -> CommandResult:
        return self.run(["auth", "can-i", "--list"])

    def apply(self, filename: str, *, execute: bool) -> CommandResult:
        args = ["apply", "-f", filename]
        if not execute:
            args += ["--dry-run=server", "-o", "yaml"]
        return self.run(args, timeout=60)

    def delete(self, resource: str, name: str, *, execute: bool) -> CommandResult:
        if not execute:
            command = self._base() + ["delete", resource, name]
            return CommandResult(command=command, returncode=0, stdout="PLAN ONLY: add --execute --yes to delete this resource.")
        return self.run(["delete", resource, name], timeout=60)

    def patch(self, resource: str, name: str, patch: str, patch_type: str, *, execute: bool) -> CommandResult:
        args = ["patch", resource, name, f"--type={patch_type}", "-p", patch]
        if not execute:
            args += ["--dry-run=server", "-o", "yaml"]
        return self.run(args, timeout=60)

    def rollout_restart(self, resource: str, name: str, *, execute: bool) -> CommandResult:
        command = self._base() + ["rollout", "restart", f"{resource}/{name}"]
        if not execute:
            return CommandResult(command=command, returncode=0, stdout="PLAN ONLY: add --execute to restart this workload.")
        return self.runner.run(command, timeout=60)

    def scale(self, resource: str, name: str, replicas: int, *, execute: bool) -> CommandResult:
        command = self._base() + ["scale", f"{resource}/{name}", f"--replicas={replicas}"]
        if not execute:
            return CommandResult(command=command, returncode=0, stdout="PLAN ONLY: add --execute to scale this workload.")
        return self.runner.run(command, timeout=60)

    def set_image(self, resource: str, name: str, container: str, image: str, *, execute: bool) -> CommandResult:
        command = self._base() + ["set", "image", f"{resource}/{name}", f"{container}={image}"]
        if not execute:
            return CommandResult(command=command, returncode=0, stdout="PLAN ONLY: add --execute to update the workload image.")
        return self.runner.run(command, timeout=60)


class HelmClient:
    """Build and run Helm commands for one kube context/namespace."""

    def __init__(
        self,
        runner: CommandRunner,
        *,
        context: str | None = None,
        namespace: str | None = None,
    ) -> None:
        self.runner = runner
        self.context = context
        self.namespace = namespace

    def _base(self) -> list[str]:
        command = ["helm"]
        if self.context:
            command += ["--kube-context", self.context]
        if self.namespace:
            command += ["--namespace", self.namespace]
        return command

    def run(self, args: Iterable[str], *, timeout: int | None = None) -> CommandResult:
        return self.runner.run(self._base() + list(args), timeout=timeout)

    def list(self, *, all_namespaces: bool = False) -> CommandResult:
        args = ["list", "-o", "json"]
        if all_namespaces:
            args.append("--all-namespaces")
        return self.run(args)

    def status(self, release: str) -> CommandResult:
        return self.run(["status", release, "-o", "json"])

    def values(self, release: str, *, all_values: bool = False) -> CommandResult:
        args = ["get", "values", release, "-o", "yaml"]
        if all_values:
            args.append("--all")
        return self.run(args)

    def manifest(self, release: str) -> CommandResult:
        return self.run(["get", "manifest", release])

    def history(self, release: str) -> CommandResult:
        return self.run(["history", release, "-o", "json"])

    def lint(self, chart: str, values_files: list[str] | None = None) -> CommandResult:
        args = ["lint", chart]
        for values_file in values_files or []:
            args += ["-f", values_file]
        return self.run(args, timeout=60)

    def template(self, release: str, chart: str, values_files: list[str] | None = None) -> CommandResult:
        args = ["template", release, chart]
        for values_file in values_files or []:
            args += ["-f", values_file]
        return self.run(args, timeout=60)

    def install(
        self,
        release: str,
        chart: str,
        *,
        values_files: list[str] | None = None,
        set_values: list[str] | None = None,
        execute: bool,
    ) -> CommandResult:
        args = ["install", release, chart]
        for values_file in values_files or []:
            args += ["-f", values_file]
        for value in set_values or []:
            args += ["--set", value]
        if not execute:
            args += ["--dry-run", "--debug"]
        else:
            args += ["--wait"]
        return self.run(args, timeout=180)

    def upgrade(
        self,
        release: str,
        chart: str,
        *,
        values_files: list[str] | None = None,
        set_values: list[str] | None = None,
        install_if_missing: bool = False,
        execute: bool,
    ) -> CommandResult:
        args = ["upgrade", release, chart]
        for values_file in values_files or []:
            args += ["-f", values_file]
        for value in set_values or []:
            args += ["--set", value]
        if install_if_missing:
            args.append("--install")
        if not execute:
            args += ["--dry-run", "--debug"]
        else:
            # Use the rollback flag that matches the installed Helm major version.
            # Helm 3 uses --atomic; Helm 4 introduced --rollback-on-failure.
            version = self.run(["version", "--template", "{{.Version}}"])
            major = 0
            if version.ok:
                text = version.stdout.lstrip("v")
                try:
                    major = int(text.split(".", 1)[0])
                except ValueError:
                    major = 0
            args += ["--wait"]
            if major >= 4:
                args += ["--rollback-on-failure"]
            elif major == 3:
                args += ["--atomic"]
        return self.run(args, timeout=300)

    def uninstall(self, release: str, *, execute: bool) -> CommandResult:
        command = self._base() + ["uninstall", release]
        if not execute:
            return CommandResult(command=command, returncode=0, stdout="PLAN ONLY: add --execute --yes to uninstall this release.")
        return self.runner.run(command, timeout=180)

    def rollback(self, release: str, revision: int, *, execute: bool) -> CommandResult:
        command = self._base() + ["rollback", release, str(revision), "--wait"]
        if not execute:
            return CommandResult(command=command, returncode=0, stdout="PLAN ONLY: add --execute to roll back this release.")
        return self.runner.run(command, timeout=180)
