# Validation record — 2026-10-25

The project was reviewed with **Helm 3.19.0**. This record distinguishes tests actually performed from tests that require your Kubernetes cluster.

## Checks performed locally

| Check | Result |
| --- | --- |
| `bash -n` on both shell scripts | PASS — valid Bash syntax |
| `helm lint keycloak-istio-stack --strict` | PASS — no chart errors |
| `helm lint keycloak-istio-stack/charts/realm --strict` | PASS — no subchart errors |
| Helm render of default lab chart | PASS — eight resources, including realm ConfigMap |
| Parse rendered YAML and `realm.json` | PASS — valid YAML/JSON and realm name `team-demo` |
| Verify PKCE client attribute | PASS — `pkce.code.challenge.method` is `S256` |
| Verify Istio host and service references | PASS — configured `keycloak.localhost` routing |
| Confirm no Kubernetes `Secret` resource is generated | PASS — references only |
| External PostgreSQL chart variant | PASS — no StatefulSet, external DB host set |
| Realm subchart disabled variant | PASS — no ConfigMap or import volume |
| Package Helm chart as `.tgz` | PASS — contains the local realm subchart |
| `helm lint` and `helm template` on packaged `.tgz` | PASS |

## Tests that must run on YOUR existing cluster

The current build environment did not provide your Docker Desktop Kubernetes cluster or its Istio gateway. The test script is supplied but has **not been executed end-to-end** against your cluster.

1. `kubectl config current-context` — verify the exact cluster.
2. `kubectl get gateways.networking.istio.io -A` — find the existing Gateway resource.
3. Execute `scripts/test-docker-desktop.sh` with `CONFIRM_CONTEXT=<exact-context>` and `GATEWAY_REF=<namespace/name>`.
4. Verify Keycloak admin login in the browser and that `team-demo` and `demo-web` exist.
5. Stop/restart a Keycloak pod and confirm the realm remains; repeat for PostgreSQL to validate storage retention.
6. Before real use, test HTTPS configuration, headers, RBAC, backups, recovery, and image admission policies.

If your cluster reports a failure, collect `kubectl describe pod`, Pod logs, and `helm get manifest`; see `REVIEW_GUIDE.md` for likely causes and commands.
