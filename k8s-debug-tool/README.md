# k8s-doctor

`k8s-doctor` is a Python command-line utility that uses the `kubectl` and `helm`
binaries already installed on your computer. It gathers common Kubernetes
troubleshooting information, reviews workload configuration, reads logs and
events, checks networking/storage clues, and provides guarded operational
commands for apply, patch, restart, scale, image updates, Helm install/upgrade,
rollback, and uninstall.

The design goal is **safe by default**:

- Read-only troubleshooting commands run immediately.
- Manifest apply and patch use server-side dry-run unless `--execute` is given.
- Restart, scale, image changes, Helm install/upgrade/rollback are plan/dry-run
  first unless `--execute` is given.
- Delete and Helm uninstall require **both** `--execute` and `--yes`.
- Secret values are redacted unless `--show-secret-data` is explicitly used.
- External commands are passed as argument arrays; the project never uses
  `shell=True`.

## 1. Requirements

- Python 3.11+
- `kubectl` installed and in `PATH`
- `helm` installed and in `PATH`
- A working Kubernetes kubeconfig/context

Check your local tools:

```bash
python3 --version
kubectl version --client
kubectl config current-context
helm version
```

## 2. Install locally

macOS/Linux:

```bash
cd k8s-debug-tool
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python -m pip install -e .
```

Windows PowerShell:

```powershell
cd k8s-debug-tool
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python -m pip install -e .
```

Then:

```bash
k8s-doctor --help
```

You can also run without installing the console command:

```bash
python -m k8s_doctor --help
```

## 3. Shared arguments can go before or after the command

The CLI normalizes shared options so both styles work:

```bash
k8s-doctor -n my-app -o human doctor
k8s-doctor doctor -n my-app -o human

k8s-doctor --context kind-kind pod web-7d9c8 -n default
k8s-doctor doctor -n my-app -o html --output-file report.html
```

This is a small convenience layer over Python `argparse` so the command feels
more like `kubectl` and `helm`.

## 4. Fast start

Run a broad health report:

```bash
k8s-doctor doctor
```

Across all namespaces:

```bash
k8s-doctor doctor -A
```

Focused networking investigation:

```bash
k8s-doctor network
k8s-doctor network -A
```

Show current RBAC capabilities:

```bash
k8s-doctor -n payments auth
```

Focused pod investigation:

```bash
k8s-doctor -n payments pod payments-api-7fbc9c6f5b-abcde
```

Recent logs:

```bash
k8s-doctor -n payments logs payments-api-7fbc9c6f5b-abcde --tail 100 --since 20m
```

Previous container logs after a restart:

```bash
k8s-doctor -n payments logs payments-api-7fbc9c6f5b-abcde --previous
```

Review a Deployment for common configuration concerns:

```bash
k8s-doctor -n payments review deployment payments-api
```

Review a local YAML manifest without touching the cluster:

```bash
k8s-doctor review-file examples/demo-deployment.yaml
```

Review Secret metadata and keys without exposing values:

```bash
k8s-doctor -n payments secret payments-db
```

## 5. Output formats

Every top-level command supports:

```text
-o human   # terminal-friendly table and details
-o json    # automation/API friendly
-o yaml    # Kubernetes-friendly structured text
-o html    # standalone browser report
```

Examples:

```bash
k8s-doctor -o json doctor > report.json
k8s-doctor -o yaml -n payments pod my-pod > pod-report.yaml
k8s-doctor -o html --output-file cluster-report.html doctor
```

## 6. Safe write operations

### Apply

Preview against the API server:

```bash
k8s-doctor -n demo apply examples/demo-deployment.yaml
```

Actually apply:

```bash
k8s-doctor -n demo apply examples/demo-deployment.yaml --execute
```

### Patch a Service

Preview:

```bash
k8s-doctor -n demo patch service demo-web '{"spec":{"type":"ClusterIP"}}'
```

Execute:

```bash
k8s-doctor -n demo patch service demo-web '{"spec":{"type":"ClusterIP"}}' --execute
```

### Restart a Deployment

```bash
k8s-doctor -n demo restart deployment demo-web
k8s-doctor -n demo restart deployment demo-web --execute
```

### Scale

```bash
k8s-doctor -n demo scale deployment demo-web 3
k8s-doctor -n demo scale deployment demo-web 3 --execute
```

### Change an image

```bash
k8s-doctor -n demo set-image deployment demo-web web nginx:1.29.1
k8s-doctor -n demo set-image deployment demo-web web nginx:1.29.1 --execute
```

### Delete

Deletion intentionally requires two flags:

```bash
k8s-doctor -n demo delete deployment demo-web --execute --yes
```

## 7. Helm examples

List releases:

```bash
k8s-doctor helm list
k8s-doctor helm list -A
```

Inspect a release:

```bash
k8s-doctor -n keycloak helm status keycloak
k8s-doctor -n keycloak helm values keycloak --all-values
k8s-doctor -n keycloak helm manifest keycloak
k8s-doctor -n keycloak helm history keycloak
```

Lint/render before installing:

```bash
k8s-doctor helm lint ./charts/my-app -f values-dev.yaml
k8s-doctor helm template my-app ./charts/my-app -f values-dev.yaml
```

Install is dry-run by default:

```bash
k8s-doctor -n demo helm install my-app ./charts/my-app -f values-dev.yaml
k8s-doctor -n demo helm install my-app ./charts/my-app -f values-dev.yaml --execute
```

Upgrade is dry-run by default:

```bash
k8s-doctor -n demo helm upgrade my-app ./charts/my-app -f values-dev.yaml
k8s-doctor -n demo helm upgrade my-app ./charts/my-app -f values-dev.yaml --execute
```

For an executed upgrade, the utility detects the Helm major version and uses
Helm 3 `--atomic` or Helm 4 `--rollback-on-failure` where appropriate.

Rollback:

```bash
k8s-doctor -n demo helm rollback my-app 2
k8s-doctor -n demo helm rollback my-app 2 --execute
```

Uninstall:

```bash
k8s-doctor -n demo helm uninstall my-app
k8s-doctor -n demo helm uninstall my-app --execute --yes
```

## 8. What `doctor` checks

The broad report checks common troubleshooting clues:

1. Cluster API connectivity.
2. kubectl client/server version output.
3. Node readiness and memory/disk/PID/network pressure.
4. Deployments, StatefulSets, and DaemonSets that are not fully ready.
5. Pods that are Pending/Failed, not ready, restarting, or waiting.
6. Services and endpoint objects with no ready addresses.
7. PersistentVolumeClaims that are not Bound.
8. Ingress and NetworkPolicy inventory.
9. CoreDNS/kube-dns pods.
10. Warning-like Kubernetes Events.
11. Metrics API availability through `kubectl top nodes`.
12. Helm release inventory.

## 9. What `review` checks

For Pods and objects with Pod templates (Deployment, StatefulSet, DaemonSet,
Job, and similar resources), it checks for:

- image tags that are unpinned or use `latest`;
- missing CPU/memory requests or limits;
- missing readiness probes;
- missing liveness probes (informational rather than automatically wrong);
- privileged containers;
- `runAsNonRoot` not explicitly enabled;
- `hostNetwork` usage;
- `hostPath` volumes.

These are **review hints**, not universal rules. Platform agents and low-level
system workloads sometimes need settings that ordinary application pods should
avoid.

## 10. Secrets

By default:

```bash
k8s-doctor -n demo secret app-secret
```

shows only the Secret type and key names. It does **not** print values.

Sensitive local-only troubleshooting:

```bash
k8s-doctor -n demo secret app-secret --show-secret-data
```

Avoid redirecting decoded secret output to shared logs, tickets, source control,
or chat tools.

## 11. Exit codes

- `0`: command/report completed without a `FAIL` finding.
- `2`: invalid usage, unavailable required binary, or at least one `FAIL` finding.
- `130`: Ctrl+C / keyboard interruption.

A warning does not automatically make the process fail because warnings often
represent troubleshooting clues rather than a definitive outage.

## 12. Project layout

```text
k8s-debug-tool/
├── k8s_doctor/
│   ├── cli.py          # argparse commands and dispatch
│   ├── clients.py      # kubectl/helm command builders
│   ├── diagnostics.py  # common Kubernetes checks
│   ├── formatters.py   # human/json/yaml/html output
│   ├── models.py       # dataclasses
│   └── runner.py       # safe subprocess execution
├── docs/
│   ├── ARCHITECTURE.md
│   ├── CODE_WALKTHROUGH.md
│   ├── COMMANDS.md
│   └── TUTORIAL.md
├── examples/
│   └── demo-deployment.yaml
├── tests/
│   └── test_core.py
├── requirements.txt
└── pyproject.toml
```

## 13. Official references

- Kubernetes kubectl overview: https://kubernetes.io/docs/concepts/overview/kubectl/
- kubectl command reference: https://kubernetes.io/docs/reference/kubectl/
- Kubernetes debugging: https://kubernetes.io/docs/tasks/debug/
- Helm docs: https://helm.sh/docs/
- Helm command reference: https://helm.sh/docs/helm/

See `docs/TUTORIAL.md` for a middle-school-level troubleshooting walkthrough and
`docs/COMMANDS.md` for the exact kubectl/Helm calls this utility uses.
