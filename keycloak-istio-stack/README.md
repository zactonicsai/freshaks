# Keycloak + PostgreSQL + Istio — Helm reference project

A readable Helm 3 chart for an **existing Kubernetes cluster** with an **existing Istio Gateway**. It includes:

- **Keycloak 26.8.1** (one non-clustered replica) and Kubernetes probes on management port 9000.
- **PostgreSQL 17.11** (one StatefulSet replica, retained persistent storage).
- **Istio `VirtualService`** routing a host name to the Keycloak ClusterIP Service.
- **Local `realm` subchart** that creates a realm-import ConfigMap and a public OIDC browser client.
- **Bash scripts** for rendering/linting and an end-to-end Docker Desktop smoke test.

This is a **well-commented learning/lab reference**, not a highly available production identity platform. Read [REVIEW_GUIDE.md](REVIEW_GUIDE.md) before deploying outside a local cluster.

## 1. Architecture at a glance

```text
Browser on Mac/Windows: http://keycloak.localhost:18080
         |
kubectl port-forward (host 18080 -> ingress gateway Service 80)
         |
Istio Gateway ALREADY IN YOUR CLUSTER
         |
VirtualService (this chart, Host: keycloak.localhost)
         |
Keycloak ClusterIP Service :8080
         |
Keycloak Deployment :8080 (health :9000, not in Service)
         |
PostgreSQL ClusterIP Service :5432
         |
PostgreSQL StatefulSet + persistent volume

Realm subchart -> ConfigMap -> mounted realm.json -> one-time Keycloak import
Kubernetes Secrets (created BEFORE Helm) -> Keycloak and PostgreSQL
```

Analogy: the **Istio Gateway** is a school's front entrance, the **VirtualService** is the sign directing visitors to the Keycloak office, Keycloak is the **ID office**, and PostgreSQL is the **filing cabinet**. The **realm** is a list of clubs and rules the ID office starts with. Only the Gateway faces the host computer.

## 2. Prerequisites

- Docker Desktop Kubernetes (or kind) running, with `kubectl` context pointing to the intended local cluster.
- Helm 3, `kubectl`, `curl`, `openssl`, `python3`, and a Bourne-compatible Bash shell.
- Istio installed and a working **Istio `Gateway` resource**, not only an ingressgateway Service. The example assumes `istio-system/local-keycloak-gateway`.
- A Kubernetes default `StorageClass` (for PostgreSQL's 5 GiB persistent claim), or set `postgresql.persistence.storageClassName`.
- A compatible existing Istio ingress gateway Service, assumed `istio-system/istio-ingressgateway`, listening at port 80.
- Ability to pull the configured container images. For offline clusters, mirror the images and override image repository/tag values. Helm itself does not fetch external charts for this project.

Check your selected cluster and resources:

```bash
kubectl config current-context
kubectl get gateways.networking.istio.io -A
kubectl -n istio-system get service istio-ingressgateway
kubectl get storageclass
```

If your Gateway is **not** `istio-system/local-keycloak-gateway`, use its real `namespace/name` in the environment variable `GATEWAY_REF`. Its HTTP listener must match the host `keycloak.localhost`, either directly or through an allowed wildcard. **The script never changes the existing Gateway.**

If you only have the ingressgateway Service but no Gateway resource, an *optional* sample resource is in `examples/gateway-local.yaml`. Review the selector/listener first; manually apply only if appropriate:

```bash
kubectl apply -f examples/gateway-local.yaml
```

The sample is not an automatic part of the chart or script.

## 3. Easiest route: one local test script

From inside the project directory:

```bash
chmod +x scripts/*.sh
./scripts/lint.sh

# First inspect what cluster you are using:
kubectl config current-context

# Replace docker-desktop with the EXACT output of the previous command.
# The equality check protects against accidentally modifying another cluster.
CONFIRM_CONTEXT=docker-desktop \
GATEWAY_REF=istio-system/local-keycloak-gateway \
./scripts/test-docker-desktop.sh
```

For a different existing Gateway or Service:

```bash
CONFIRM_CONTEXT=docker-desktop \
GATEWAY_REF=istio-system/my-existing-gateway \
INGRESS_SERVICE_NAMESPACE=istio-system \
INGRESS_SERVICE=istio-ingressgateway \
LOCAL_PORT=18080 \
./scripts/test-docker-desktop.sh
```

The script:

1. Confirms the current Kubernetes context matches the `CONFIRM_CONTEXT` you supplied.
2. Checks that the Istio Gateway resource and Service exist and the Gateway allows the host.
3. Creates namespace `identity-demo` if needed, and creates **two secrets with random passwords** if missing.
4. Runs `helm lint` and renders both bundled configurations, then runs `helm upgrade --install --wait --atomic`.
5. Checks the Deployment and StatefulSet rollout; runs `helm test` for internal OIDC discovery.
6. Temporarily port-forwards the ingress Service to the host and requests public OIDC discovery through Istio.
7. Checks the `issuer` value in OIDC JSON against the expected Keycloak URL, reports PASS/FAIL, and stops its temporary port-forward.

**Important:** The script makes real changes in the selected cluster and reuses existing Secrets without overwriting them. `--atomic` rolls back/uninstalls failed releases, but persistent volume claims and secrets can remain. It intentionally does not delete data.

## 4. Browse Keycloak from your host computer

The test closes its temporary port-forward. Keep this running **in a second terminal** for the browser:

```bash
kubectl -n istio-system port-forward svc/istio-ingressgateway 18080:80
```

Then open:

- **Admin console:** <http://keycloak.localhost:18080/admin/>
- **Demo realm:** <http://keycloak.localhost:18080/realms/team-demo>
- **OIDC discovery:** <http://keycloak.localhost:18080/realms/team-demo/.well-known/openid-configuration>

On modern desktop browsers, `.localhost` is intended for loopback. If your browser does not resolve it, add `127.0.0.1 keycloak.localhost` to the **host computer's** hosts file (not a Docker container's). Use `curl --resolve keycloak.localhost:18080:127.0.0.1 ...` to test without any hosts-file change.

Retrieve the bootstrap admin credentials:

```bash
kubectl -n identity-demo get secret keycloak-admin -o jsonpath='{.data.username}' | base64 --decode
echo
kubectl -n identity-demo get secret keycloak-admin -o jsonpath='{.data.password}' | base64 --decode
echo
```

On versions of macOS where `base64 --decode` is unavailable, replace it with `base64 -D`. Keep these values private. The password is only used to **bootstrap** the admin on the initial Keycloak database; changing the Secret alone later does not reset a user account's password.

## 5. Manual deployment without the test script

First create the namespace and two secrets using a secret manager or local secure input. This illustrates the expected Kubernetes key names without placing passwords in Git:

```bash
kubectl create namespace identity-demo
kubectl -n identity-demo create secret generic keycloak-db \
  --from-literal=password='REPLACE_WITH_YOUR_LOCAL_TEST_SECRET'
kubectl -n identity-demo create secret generic keycloak-admin \
  --from-literal=username=admin \
  --from-literal=password='REPLACE_WITH_ANOTHER_LOCAL_TEST_SECRET'

helm lint . --strict
helm template identity . -n identity-demo -f values-local.yaml
helm upgrade --install identity . -n identity-demo -f values-local.yaml --wait --timeout 10m --atomic
helm test identity -n identity-demo --logs
```

**Security note:** The `--from-literal` form is easy to understand, but can expose the password in shell history or command-line process inspection. Prefer the script's short-lived secure files, a secrets manager/External Secrets controller, or `kubectl create secret --from-file` for real use. Never commit Secret YAML or actual credentials.

## 6. Quick map of the chart files

| File | What it controls | Reviewer question |
| --- | --- | --- |
| `Chart.yaml` | Root metadata + local realm chart dependency | Can we build without public chart repositories? |
| `values.yaml` | Images, runtime settings, database, gateway, realm | Are defaults safe for the target environment? |
| `values-local.yaml` | Host and Gateway reference for local setup | Does the existing Gateway allow this Host? |
| `values.schema.json` | Stops common invalid value overrides | Are missing/invalid values rejected before deployment? |
| `templates/_helpers.tpl` | Shared names and labels | Are naming/label conventions consistent? |
| `templates/keycloak-deployment.yaml` | Keycloak pod, env references, probes, realm mount | Does any sensitive information end up in values? |
| `templates/keycloak-service.yaml` | Internal Keycloak :8080 only | Is port 9000 inaccessible through ingress? |
| `templates/postgresql-statefulset.yaml` | PostgreSQL storage, security, probes | Will data survive pod replacement? |
| `templates/postgresql-services.yaml` | App-facing and headless PostgreSQL Services | Does each Service select the intended pods? |
| `templates/virtualservice.yaml` | Existing Gateway -> Keycloak Service route | Does the hostname match the Gateway listener? |
| `charts/realm/templates/realm-configmap.yaml` | Import JSON, demo client and roles | Is realm bootstrapping confused with continuous sync? |
| `templates/tests/oidc-smoke.yaml` | `helm test` against the internal service | Does realm OIDC discovery return HTTP 200? |
| `scripts/test-docker-desktop.sh` | Safe-context install, port-forward, verification | Can a reviewer reproduce the local test? |

## 7. How to customize

**Existing PostgreSQL instead of the included database**:

```bash
helm upgrade --install identity . -n identity-demo \
  -f values-local.yaml \
  --set postgresql.enabled=false \
  --set database.host=postgres.example.internal \
  --wait
```

This assumes that an external database already exists and accepts connections for `database.username` and that the referenced `keycloak-db` Secret holds the password. A managed PostgreSQL service should generally require encrypted connections; this minimal chart does not yet mount custom CA bundles or configure `KC_DB_URL_PROPERTIES` for TLS. Add those controls before production deployment.

**Change the initial realm**: edit the `realm:` section in `values.yaml`. The subchart translates roles and clients into `realm.json`, which is mounted at `/opt/keycloak/data/import`. Keycloak's `start --import-realm` only imports the realm **when it does not exist**. Changing a client's redirect URI later in Helm will update the ConfigMap, but **not** the existing realm in PostgreSQL. Make live changes through Keycloak Admin API, `kcadm.sh`, or a deliberate realm reconciliation controller and review drift/backup behavior.

**Work offline**: override the two image repositories with your internal mirror, mirror `curlimages/curl` or replace the optional smoke-test Pod image, and ensure Istio/Kubernetes components are already installed. The local `realm` subchart does not require network downloads.

## 8. Operations and cleanup

```bash
kubectl -n identity-demo get deploy,sts,pods,svc,pvc
kubectl -n identity-demo get virtualservices.networking.istio.io
kubectl -n identity-demo describe pod -l app.kubernetes.io/name=keycloak
kubectl -n identity-demo logs deploy/identity-keycloak-istio-stack-keycloak --tail=100
kubectl -n identity-demo logs sts/identity-keycloak-istio-stack-postgresql --tail=100
helm history identity -n identity-demo
helm uninstall identity -n identity-demo
```

Uninstalling the release deletes chart-managed Kubernetes objects but **normally leaves PostgreSQL's StatefulSet PVC** and the separately created Secrets. This is intentional to protect data. Verify them before deleting anything; do **not** delete the PVC casually. To reconnect to retained PostgreSQL data after reinstalling, preserve the database Secret and StatefulSet naming.

## 9. Background/reference documentation

- [Keycloak container setup and realm import](https://www.keycloak.org/server/containers)
- [Keycloak import behavior](https://www.keycloak.org/server/importExport)
- [Keycloak reverse proxy and trusted headers](https://www.keycloak.org/server/reverseproxy)
- [Keycloak health endpoint](https://www.keycloak.org/observability/health)
- [Istio VirtualService API](https://istio.io/latest/docs/reference/config/networking/virtual-service/)
- [Istio Gateways](https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/)
- [Helm chart dependencies](https://helm.sh/docs/helm/helm_dependency/)
- [PostgreSQL versioning and security updates](https://www.postgresql.org/support/versioning/)

See [REVIEW_GUIDE.md](REVIEW_GUIDE.md) for a section-by-section rationale and production migration checklist.
