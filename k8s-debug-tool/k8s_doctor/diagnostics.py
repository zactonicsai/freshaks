"""Kubernetes diagnostic checks.

The checks favor useful, common failure modes over vendor-specific assumptions.
All checks are read-only. Secret values are never included unless the caller
explicitly asks for a single secret's decoded data.
"""

from __future__ import annotations

import base64
from pathlib import Path
from typing import Any

import yaml

from .clients import HelmClient, KubectlClient
from .models import Report
from .runner import CommandRunner


def _items(obj: Any) -> list[dict[str, Any]]:
    if isinstance(obj, dict) and isinstance(obj.get("items"), list):
        return [item for item in obj["items"] if isinstance(item, dict)]
    return []


def _name(item: dict[str, Any]) -> str:
    return str(item.get("metadata", {}).get("name", "<unknown>"))


def _ns(item: dict[str, Any]) -> str:
    return str(item.get("metadata", {}).get("namespace", "default"))


class DiagnosticsService:
    """Run reusable health and troubleshooting checks."""

    def __init__(self, kubectl: KubectlClient, helm: HelmClient) -> None:
        self.kubectl = kubectl
        self.helm = helm

    def full_report(self, *, all_namespaces: bool = False) -> Report:
        context_result = self.kubectl.current_context()
        context = context_result.stdout or self.kubectl.context
        report = Report(title="Kubernetes Diagnostic Report", context=context, namespace=self.kubectl.namespace)
        self._check_connectivity(report)
        self._check_nodes(report)
        self._check_workloads(report, all_namespaces=all_namespaces)
        self._check_pods(report, all_namespaces=all_namespaces)
        self._check_services(report, all_namespaces=all_namespaces)
        self._check_storage(report, all_namespaces=all_namespaces)
        self._check_networking(report, all_namespaces=all_namespaces)
        self._check_events(report, all_namespaces=all_namespaces)
        self._check_metrics(report)
        self._check_helm(report, all_namespaces=all_namespaces)
        return report

    def network_report(self, *, all_namespaces: bool = False) -> Report:
        """Create a focused networking report without running every cluster check."""

        context_result = self.kubectl.current_context()
        report = Report(title="Kubernetes Networking Report", context=context_result.stdout, namespace=self.kubectl.namespace)
        self._check_services(report, all_namespaces=all_namespaces)
        self._check_networking(report, all_namespaces=all_namespaces)
        self._check_events(report, all_namespaces=all_namespaces)
        return report

    def auth_report(self) -> Report:
        """Show the current identity's Kubernetes authorization capabilities."""

        context_result = self.kubectl.current_context()
        report = Report(title="Kubernetes Authorization Report", context=context_result.stdout, namespace=self.kubectl.namespace)
        result = self.kubectl.auth_can_i()
        report.add(
            "RBAC permissions",
            "PASS" if result.ok else "FAIL",
            "kubectl auth can-i --list completed" if result.ok else "Could not list current permissions",
            details=result.stdout or result.stderr,
            command=CommandRunner.printable(result.command),
        )
        return report

    def file_review(self, filename: str) -> Report:
        """Review a local Kubernetes YAML file without contacting the cluster."""

        report = Report(title=f"Local Manifest Review: {filename}", context=self.kubectl.context, namespace=self.kubectl.namespace)
        path = Path(filename)
        if not path.exists() or not path.is_file():
            report.add("file", "FAIL", "Manifest file does not exist", details=str(path))
            return report
        try:
            documents = [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if isinstance(doc, dict)]
        except (OSError, yaml.YAMLError) as exc:
            report.add("parse", "FAIL", "Could not parse YAML", details=str(exc))
            return report
        report.add("parse", "PASS", f"Parsed {len(documents)} Kubernetes YAML document(s)")
        for index, obj in enumerate(documents, start=1):
            kind = str(obj.get("kind", "<unknown>"))
            name = str(obj.get("metadata", {}).get("name", "<unnamed>"))
            report.add(f"document {index}", "INFO", f"{kind}/{name}", details={"apiVersion": obj.get("apiVersion")})
            pod_spec = self._find_pod_spec(obj)
            if pod_spec:
                self._review_pod_spec(report, pod_spec)
            if kind.lower() == "service":
                spec = obj.get("spec", {})
                selector = spec.get("selector") or {}
                if not selector and spec.get("type") != "ExternalName":
                    report.add(f"service selector:{name}", "WARN", "Service has no selector", recommendation="A selector-less Service can be intentional, but ordinary app Services need matching Pod labels or manually managed EndpointSlices.")
                if spec.get("type") in {"NodePort", "LoadBalancer"}:
                    report.add(f"service exposure:{name}", "INFO", f"Service type is {spec.get('type')}", recommendation="Confirm that external exposure is intentional and protected by network/security controls.")
        return report

    def pod_report(self, pod: str, *, show_secret_data: bool = False) -> Report:
        context_result = self.kubectl.current_context()
        report = Report(title=f"Pod Debug Report: {pod}", context=context_result.stdout, namespace=self.kubectl.namespace)
        result, obj = self.kubectl.get_json("pod", pod)
        if not result.ok or not isinstance(obj, dict):
            report.add("pod exists", "FAIL", f"Could not read pod {pod}", details=result.stderr, command=CommandRunner.printable(result.command))
            return report

        status = obj.get("status", {})
        spec = obj.get("spec", {})
        report.add("phase", "PASS" if status.get("phase") == "Running" else "WARN", f"Pod phase is {status.get('phase', 'Unknown')}", details=status.get("conditions"))

        container_details = []
        for cs in status.get("containerStatuses", []) or []:
            state = cs.get("state", {})
            waiting = state.get("waiting") or {}
            terminated = state.get("terminated") or {}
            container_details.append(
                {
                    "name": cs.get("name"),
                    "ready": cs.get("ready"),
                    "restartCount": cs.get("restartCount"),
                    "waitingReason": waiting.get("reason"),
                    "terminatedReason": terminated.get("reason"),
                    "lastState": cs.get("lastState"),
                }
            )
        bad = [c for c in container_details if not c.get("ready") or (c.get("restartCount") or 0) > 0]
        report.add("containers", "WARN" if bad else "PASS", f"{len(container_details)} container status record(s); {len(bad)} need attention", details=container_details)

        report.add("scheduling", "INFO", f"Node: {spec.get('nodeName', '<not scheduled>')}", details={"nodeSelector": spec.get("nodeSelector"), "tolerations": spec.get("tolerations"), "affinity": spec.get("affinity")})

        describe = self.kubectl.describe("pod", pod)
        report.add("describe", "PASS" if describe.ok else "WARN", "kubectl describe output", details=describe.stdout or describe.stderr, command=CommandRunner.printable(describe.command))

        events = self.kubectl.run(["get", "events", f"--field-selector=involvedObject.name={pod}", "--sort-by=.lastTimestamp"])
        report.add("pod events", "PASS" if events.ok else "WARN", "Events related to this pod", details=events.stdout or events.stderr, command=CommandRunner.printable(events.command))

        for container in [c.get("name") for c in spec.get("containers", []) or [] if c.get("name")]:
            logs = self.kubectl.logs(pod, container=container, tail=120)
            report.add(f"logs:{container}", "PASS" if logs.ok else "WARN", "Recent container logs", details=logs.stdout or logs.stderr, command=CommandRunner.printable(logs.command))
            previous = self.kubectl.logs(pod, container=container, tail=80, previous=True)
            if previous.ok and previous.stdout:
                report.add(f"previous logs:{container}", "WARN", "Previous container logs exist; this can help explain a restart", details=previous.stdout, command=CommandRunner.printable(previous.command))

        self._check_pod_references(report, obj, show_secret_data=show_secret_data)
        return report

    def secret_report(self, secret: str, *, show_data: bool = False) -> Report:
        context_result = self.kubectl.current_context()
        report = Report(title=f"Secret Review: {secret}", context=context_result.stdout, namespace=self.kubectl.namespace)
        result, obj = self.kubectl.get_json("secret", secret)
        if not result.ok or not isinstance(obj, dict):
            report.add("secret", "FAIL", "Secret could not be read", details=result.stderr, command=CommandRunner.printable(result.command))
            return report
        data = obj.get("data") or {}
        report.add("metadata", "PASS", f"Secret exists with {len(data)} key(s)", details={"type": obj.get("type"), "keys": sorted(data.keys())})
        if show_data:
            decoded = {}
            for key, value in data.items():
                try:
                    decoded[key] = base64.b64decode(value).decode("utf-8", errors="replace")
                except Exception as exc:  # defensive: malformed secret data should not crash report generation
                    decoded[key] = f"<decode error: {exc}>"
            report.add("decoded data", "WARN", "Sensitive data explicitly requested; handle this output carefully", details=decoded, recommendation="Do not paste decoded secrets into tickets, chat systems, or source control.")
        else:
            report.add("decoded data", "INFO", "Secret values are redacted by default", recommendation="Use --show-secret-data only when you truly need local decoded values.")
        return report

    def config_review(self, resource: str, name: str) -> Report:
        context_result = self.kubectl.current_context()
        report = Report(title=f"Configuration Review: {resource}/{name}", context=context_result.stdout, namespace=self.kubectl.namespace)
        result, obj = self.kubectl.get_json(resource, name)
        if not result.ok or not isinstance(obj, dict):
            report.add("resource", "FAIL", "Resource could not be read", details=result.stderr, command=CommandRunner.printable(result.command))
            return report
        report.add("resource", "PASS", "Resource configuration loaded", details={"apiVersion": obj.get("apiVersion"), "kind": obj.get("kind"), "name": obj.get("metadata", {}).get("name")})
        pod_spec = self._find_pod_spec(obj)
        if pod_spec:
            self._review_pod_spec(report, pod_spec)
        else:
            report.add("pod template", "INFO", "This resource does not contain a recognized pod template")
        return report

    def _check_connectivity(self, report: Report) -> None:
        cluster_info = self.kubectl.cluster_info()
        report.add("cluster connectivity", "PASS" if cluster_info.ok else "FAIL", "API server is reachable" if cluster_info.ok else "Cannot reach the cluster API", details=cluster_info.stdout or cluster_info.stderr, recommendation=None if cluster_info.ok else "Check kubeconfig, current context, VPN/network access, credentials, and API server reachability.", command=CommandRunner.printable(cluster_info.command))
        version = self.kubectl.version()
        report.add("client/server version", "PASS" if version.ok else "WARN", "kubectl version information", details=version.stdout or version.stderr, recommendation="Keep kubectl within the Kubernetes supported minor-version skew for your cluster.", command=CommandRunner.printable(version.command))

    def _check_nodes(self, report: Report) -> None:
        result, obj = self.kubectl.get_json("nodes", all_namespaces=True)
        if not result.ok or obj is None:
            report.add("nodes", "FAIL", "Could not list nodes", details=result.stderr, command=CommandRunner.printable(result.command))
            return
        nodes = _items(obj)
        problems = []
        details = []
        for node in nodes:
            conditions = node.get("status", {}).get("conditions", []) or []
            ready = next((c for c in conditions if c.get("type") == "Ready"), {})
            pressures = [c.get("type") for c in conditions if c.get("type") in {"MemoryPressure", "DiskPressure", "PIDPressure", "NetworkUnavailable"} and c.get("status") == "True"]
            entry = {"name": _name(node), "ready": ready.get("status"), "reason": ready.get("reason"), "pressures": pressures}
            details.append(entry)
            if ready.get("status") != "True" or pressures:
                problems.append(entry)
        report.add("nodes", "WARN" if problems else "PASS", f"{len(nodes)} node(s); {len(problems)} with readiness/pressure concerns", details=details, recommendation="Use `kubectl describe node NAME` for any node marked NotReady or under pressure." if problems else None)

    def _check_workloads(self, report: Report, *, all_namespaces: bool) -> None:
        for resource in ("deployments", "statefulsets", "daemonsets"):
            result, obj = self.kubectl.get_json(resource, all_namespaces=all_namespaces)
            if not result.ok or obj is None:
                report.add(resource, "WARN", f"Could not list {resource}", details=result.stderr)
                continue
            problems = []
            rows = []
            for item in _items(obj):
                spec = item.get("spec", {})
                status = item.get("status", {})
                if resource == "daemonsets":
                    desired = status.get("desiredNumberScheduled", 0)
                    ready = status.get("numberReady", 0)
                else:
                    desired = spec.get("replicas", 1)
                    ready = status.get("readyReplicas", 0) or 0
                row = {"namespace": _ns(item), "name": _name(item), "desired": desired, "ready": ready}
                rows.append(row)
                if desired != ready:
                    problems.append(row)
            report.add(resource, "WARN" if problems else "PASS", f"{len(rows)} found; {len(problems)} not fully ready", details=problems or rows)

    def _check_pods(self, report: Report, *, all_namespaces: bool) -> None:
        result, obj = self.kubectl.get_json("pods", all_namespaces=all_namespaces)
        if not result.ok or obj is None:
            report.add("pods", "FAIL", "Could not list pods", details=result.stderr)
            return
        problems = []
        for pod in _items(obj):
            phase = pod.get("status", {}).get("phase")
            statuses = pod.get("status", {}).get("containerStatuses", []) or []
            restarts = sum(int(cs.get("restartCount", 0) or 0) for cs in statuses)
            waiting_reasons = [((cs.get("state") or {}).get("waiting") or {}).get("reason") for cs in statuses]
            waiting_reasons = [reason for reason in waiting_reasons if reason]
            ready = all(bool(cs.get("ready")) for cs in statuses) if statuses else False
            if phase not in {"Running", "Succeeded"} or (phase == "Running" and not ready) or restarts > 0 or waiting_reasons:
                problems.append({"namespace": _ns(pod), "name": _name(pod), "phase": phase, "ready": ready, "restarts": restarts, "waiting": waiting_reasons})
        report.add("pods", "WARN" if problems else "PASS", f"{len(_items(obj))} pod(s); {len(problems)} with common warning signs", details=problems, recommendation="Run `k8s-doctor pod POD -n NAMESPACE` for a focused report." if problems else None)

    def _check_services(self, report: Report, *, all_namespaces: bool) -> None:
        result, services = self.kubectl.get_json("services", all_namespaces=all_namespaces)
        if not result.ok or services is None:
            report.add("services", "WARN", "Could not list services", details=result.stderr)
            return
        rows = []
        for svc in _items(services):
            spec = svc.get("spec", {})
            rows.append({"namespace": _ns(svc), "name": _name(svc), "type": spec.get("type"), "clusterIP": spec.get("clusterIP"), "ports": spec.get("ports")})
        report.add("services", "INFO", f"{len(rows)} service(s) found", details=rows)

        ep_result, eps = self.kubectl.get_json("endpoints", all_namespaces=all_namespaces)
        if ep_result.ok and eps is not None:
            empty = []
            for ep in _items(eps):
                if _name(ep) == "kubernetes":
                    continue
                addresses = 0
                for subset in ep.get("subsets", []) or []:
                    addresses += len(subset.get("addresses", []) or [])
                if addresses == 0:
                    empty.append({"namespace": _ns(ep), "name": _name(ep)})
            report.add("service endpoints", "WARN" if empty else "PASS", f"{len(empty)} endpoint object(s) have no ready addresses", details=empty, recommendation="For an empty Service endpoint, compare the Service selector with Pod labels and check Pod readiness." if empty else None)

    def _check_storage(self, report: Report, *, all_namespaces: bool) -> None:
        result, pvcs = self.kubectl.get_json("pvc", all_namespaces=all_namespaces)
        if not result.ok or pvcs is None:
            report.add("persistent volume claims", "INFO", "PVCs could not be listed or are not accessible", details=result.stderr)
            return
        pending = [{"namespace": _ns(pvc), "name": _name(pvc), "phase": pvc.get("status", {}).get("phase"), "storageClass": pvc.get("spec", {}).get("storageClassName")} for pvc in _items(pvcs) if pvc.get("status", {}).get("phase") != "Bound"]
        report.add("persistent volume claims", "WARN" if pending else "PASS", f"{len(_items(pvcs))} PVC(s); {len(pending)} not Bound", details=pending)

    def _check_networking(self, report: Report, *, all_namespaces: bool) -> None:
        ing_result, ing = self.kubectl.get_json("ingresses", all_namespaces=all_namespaces)
        if ing_result.ok and ing is not None:
            rows = [{"namespace": _ns(i), "name": _name(i), "class": i.get("spec", {}).get("ingressClassName"), "hosts": [r.get("host") for r in i.get("spec", {}).get("rules", []) or []]} for i in _items(ing)]
            report.add("ingress", "INFO", f"{len(rows)} ingress resource(s)", details=rows)
        np_result, nps = self.kubectl.get_json("networkpolicies", all_namespaces=all_namespaces)
        if np_result.ok and nps is not None:
            report.add("network policies", "INFO", f"{len(_items(nps))} NetworkPolicy resource(s) found", details=[{"namespace": _ns(n), "name": _name(n)} for n in _items(nps)], recommendation="When traffic is unexpectedly blocked, check both ingress and egress policies for the source and destination namespaces.")
        dns = self.kubectl.run(["get", "pods", "-n", "kube-system", "-l", "k8s-app=kube-dns", "-o", "wide"], namespaced=False)
        report.add("cluster DNS pods", "PASS" if dns.ok and dns.stdout else "WARN", "CoreDNS/kube-dns pod lookup", details=dns.stdout or dns.stderr, command=CommandRunner.printable(dns.command))

    def _check_events(self, report: Report, *, all_namespaces: bool) -> None:
        events = self.kubectl.events(all_namespaces=all_namespaces)
        text = events.stdout or events.stderr
        warning_lines = [line for line in text.splitlines() if "Warning" in line or "Failed" in line or "BackOff" in line]
        report.add("events", "WARN" if warning_lines else ("PASS" if events.ok else "WARN"), f"{len(warning_lines)} warning-like event line(s) detected", details=warning_lines[-40:] if warning_lines else text[-4000:], recommendation="Recent Warning events often explain scheduling, image pull, volume, probe, and crash-loop problems." if warning_lines else None, command=CommandRunner.printable(events.command))

    def _check_metrics(self, report: Report) -> None:
        top_nodes = self.kubectl.top("nodes")
        report.add("resource metrics", "PASS" if top_nodes.ok else "INFO", "kubectl top nodes succeeded" if top_nodes.ok else "Metrics API is not available to kubectl top", details=top_nodes.stdout or top_nodes.stderr, recommendation=None if top_nodes.ok else "If CPU/memory metrics are needed, verify Metrics Server (or your platform metrics adapter) is installed and healthy.", command=CommandRunner.printable(top_nodes.command))

    def _check_helm(self, report: Report, *, all_namespaces: bool) -> None:
        result = self.helm.list(all_namespaces=all_namespaces)
        report.add("helm releases", "PASS" if result.ok else "INFO", "Helm release inventory", details=result.stdout or result.stderr, command=CommandRunner.printable(result.command))

    def _check_pod_references(self, report: Report, pod: dict[str, Any], *, show_secret_data: bool) -> None:
        spec = pod.get("spec", {})
        configmaps: set[str] = set()
        secrets: set[str] = set()
        for container in (spec.get("containers", []) or []) + (spec.get("initContainers", []) or []):
            for env_from in container.get("envFrom", []) or []:
                if env_from.get("configMapRef", {}).get("name"):
                    configmaps.add(env_from["configMapRef"]["name"])
                if env_from.get("secretRef", {}).get("name"):
                    secrets.add(env_from["secretRef"]["name"])
            for env in container.get("env", []) or []:
                ref = (env.get("valueFrom") or {})
                if ref.get("configMapKeyRef", {}).get("name"):
                    configmaps.add(ref["configMapKeyRef"]["name"])
                if ref.get("secretKeyRef", {}).get("name"):
                    secrets.add(ref["secretKeyRef"]["name"])
        for volume in spec.get("volumes", []) or []:
            if volume.get("configMap", {}).get("name"):
                configmaps.add(volume["configMap"]["name"])
            if volume.get("secret", {}).get("secretName"):
                secrets.add(volume["secret"]["secretName"])

        for cm in sorted(configmaps):
            result, obj = self.kubectl.get_json("configmap", cm)
            report.add(f"configmap:{cm}", "PASS" if result.ok else "FAIL", "Referenced ConfigMap exists" if result.ok else "Referenced ConfigMap is missing/unreadable", details=sorted((obj or {}).get("data", {}).keys()) if result.ok else result.stderr)
        for secret in sorted(secrets):
            result, obj = self.kubectl.get_json("secret", secret)
            if result.ok and isinstance(obj, dict):
                keys = sorted((obj.get("data") or {}).keys())
                details: Any = {"keys": keys, "values": "redacted"}
                if show_secret_data:
                    details = {key: base64.b64decode(value).decode("utf-8", errors="replace") for key, value in (obj.get("data") or {}).items()}
                report.add(f"secret:{secret}", "WARN" if show_secret_data else "PASS", "Referenced Secret exists", details=details)
            else:
                report.add(f"secret:{secret}", "FAIL", "Referenced Secret is missing/unreadable", details=result.stderr)

    @staticmethod
    def _find_pod_spec(obj: dict[str, Any]) -> dict[str, Any] | None:
        kind = str(obj.get("kind", "")).lower()
        if kind == "pod":
            return obj.get("spec")
        template = obj.get("spec", {}).get("template", {})
        if isinstance(template, dict) and isinstance(template.get("spec"), dict):
            return template["spec"]
        return None

    @staticmethod
    def _review_pod_spec(report: Report, spec: dict[str, Any]) -> None:
        containers = spec.get("containers", []) or []
        for container in containers:
            name = container.get("name", "<unnamed>")
            image = str(container.get("image", ""))
            if image.endswith(":latest") or ":" not in image.rsplit("/", 1)[-1]:
                report.add(f"image:{name}", "WARN", f"Image is not pinned to a specific version: {image}", recommendation="Use an immutable digest or a controlled version tag for repeatable deployments.")
            else:
                report.add(f"image:{name}", "PASS", f"Image has an explicit tag/digest: {image}")

            resources = container.get("resources") or {}
            if not resources.get("requests") or not resources.get("limits"):
                report.add(f"resources:{name}", "WARN", "CPU/memory requests or limits are incomplete", details=resources, recommendation="Define realistic requests for scheduling and limits where appropriate for workload protection.")
            else:
                report.add(f"resources:{name}", "PASS", "Resource requests and limits are present", details=resources)

            if not container.get("readinessProbe"):
                report.add(f"readiness probe:{name}", "WARN", "No readinessProbe configured", recommendation="Add a readiness probe so Services only send traffic to ready containers.")
            if not container.get("livenessProbe"):
                report.add(f"liveness probe:{name}", "INFO", "No livenessProbe configured", recommendation="Use a liveness probe only when the application can reliably detect a stuck state; avoid probes that cause restart loops.")

            security = container.get("securityContext") or {}
            if security.get("privileged") is True:
                report.add(f"security:{name}", "FAIL", "Container is privileged", recommendation="Avoid privileged containers unless there is a documented platform requirement.")
            if security.get("runAsNonRoot") is not True:
                report.add(f"security:{name}", "INFO", "runAsNonRoot is not explicitly true", recommendation="Where the image supports it, run as a non-root user and set an appropriate securityContext.")

        if spec.get("hostNetwork"):
            report.add("hostNetwork", "WARN", "Pod uses the host network namespace", recommendation="Use hostNetwork only when required because it reduces network isolation.")
        host_paths = [v.get("hostPath") for v in spec.get("volumes", []) or [] if v.get("hostPath")]
        if host_paths:
            report.add("hostPath", "WARN", f"{len(host_paths)} hostPath volume(s) found", details=host_paths, recommendation="Prefer managed volumes; hostPath tightly couples a workload to node filesystem paths.")
