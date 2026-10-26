# keycloak-stack

A single Helm chart that deploys **Keycloak** backed by **PostgreSQL** and exposes it through an
**existing Istio ingress Gateway** (`istio-system/key-gate` by default) with a **VirtualService**.
Every value is validated by `values.schema.json`, so typos and impossible combinations fail at
`helm install` time instead of at 3 a.m.

```
Internet ──TLS──▶ Istio Gateway "key-gate" (already in your cluster)
                        │  VirtualService (this chart)  host: keycloak.example.com
                        ▼
            ┌──── namespace: <release ns> ──────────────────────────────┐
            │  Service keycloak :8080 (http) :9000 (http-mgmt)          │
            │     │ DestinationRule (sticky AUTH_SESSION_ID, outlier)   │
            │     ▼                                                     │
            │  Deployment keycloak ×N  ◀──JGroups 7800──▶ (replicas)    │
            │     │ KC_DB_* env, password from Secret                   │
            │     ▼                                                     │
            │  Service postgresql :5432 (tcp)                           │
            │  StatefulSet postgresql + PVC (Retain on uninstall)       │
            │                                                           │
            │  PeerAuthentication STRICT · NetworkPolicy · PDB · HPA    │
            └───────────────────────────────────────────────────────────┘
```

---

## 1. What is in the chart

| File | Resources | Why it exists |
|---|---|---|
| `Chart.yaml` | – | Chart metadata. `appVersion` doubles as the default Keycloak image tag. |
| `values.yaml` | – | All tunables, commented. |
| `values.schema.json` | – | JSON-Schema (draft-07). Rejects unknown keys, bad enums, malformed hostnames/durations, and enforces cross-field rules (external DB host required when bundled Postgres is off). |
| `templates/_helpers.tpl` | – | Naming, labels, image strings, DB connection facts, and `ks.stablePassword` (password generated once, preserved on upgrade via `lookup`). |
| `templates/secrets.yaml` | 2–3 × `Secret` | Admin bootstrap password, Postgres password, optional external-DB password. Skipped entirely when you supply `existingSecret`. |
| `templates/serviceaccounts.yaml` | 2 × `ServiceAccount` | Dedicated identities (Istio AuthorizationPolicy uses them). No API token mounted. |
| `templates/postgresql.yaml` | `Service`, `StatefulSet` (+PVC template) | Single-node PostgreSQL 16 with data checksums, read-only root FS, PVC retained on uninstall. |
| `templates/keycloak-deployment.yaml` | `Deployment` | Keycloak 26 in production mode (`kc.sh start`), hostname v2, X-Forwarded proxy headers, health + metrics on the management port, Infinispan clustering. |
| `templates/keycloak-services.yaml` | `Service`, headless `Service` | `http`/`http-mgmt` ports named for Istio protocol selection; headless service for JGroups DNS_PING. |
| `templates/istio.yaml` | `VirtualService`, `DestinationRule`, 2 × `PeerAuthentication` | Edge routing on the existing gateway, sticky sessions, mTLS enforcement. |
| `templates/istio-authorizationpolicy.yaml` | 2 × `AuthorizationPolicy` (opt-in) | Identity allow-list: only the gateway may call Keycloak; only Keycloak may call Postgres. |
| `templates/networkpolicy.yaml` | 2 × `NetworkPolicy` | L3/L4 belt-and-braces for the above; ingress-only so sidecars can still reach istiod. |
| `templates/keycloak-pdb-hpa.yaml` | `PodDisruptionBudget`, `HorizontalPodAutoscaler` | HA guard-rails; PDB only rendered when >1 replica. |
| `templates/tests/test-readiness.yaml` | `Pod` (helm test hook) | `helm test` curls `/health/ready`. |
| `templates/NOTES.txt` | – | Post-install instructions (URLs, how to read the admin password). |

---

## 2. Quick start

```bash
# 0. Prerequisites: Istio installed, a Gateway named key-gate in istio-system
#    whose server block lists your host (or a wildcard), and a TLS credential on it.
kubectl -n istio-system get gateway key-gate -o yaml | grep -A3 hosts

# 1. Namespace with sidecar injection
kubectl create ns identity
kubectl label ns identity istio-injection=enabled

# 2. Install
helm install keycloak ./keycloak-stack -n identity \
  --set istio.hosts[0]=keycloak.example.com

# 3. Watch it come up (first start runs DB migrations: ~1–2 min)
kubectl -n identity rollout status deploy/keycloak-keycloak-stack-keycloak
helm test keycloak -n identity

# 4. Admin password (generated once, stable across upgrades)
kubectl -n identity get secret keycloak-keycloak-stack-keycloak-admin \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Open `https://keycloak.example.com/admin/` (DNS must point at the gateway's load balancer).

### Production-shaped install

```yaml
# values-prod.yaml
istio:
  hosts: [sso.corp.example]
  gateway: { name: key-gate, namespace: istio-system }
  virtualService:
    blockAdminConsole: true          # admin UI not reachable from the internet
  authorizationPolicy:
    enabled: true
    ingressGatewayPrincipals:
      - cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account

keycloak:
  replicaCount: 3
  args: ["start", "--optimized"]     # see §6.3
  image:
    repository: your-registry/keycloak-optimized
    tag: "26.0.7-1"
  containerSecurityContext:
    readOnlyRootFilesystem: true     # safe once --optimized
  admin:
    existingSecret: keycloak-admin   # keys: username, password
  resources:
    requests: { cpu: "1", memory: 2Gi }
    limits:   { memory: 3Gi }
  hostnameAdmin: https://sso-admin.corp.internal

postgresql:
  enabled: false
externalDatabase:
  host: keycloak-db-rw.database.svc   # e.g. CloudNativePG RW service
  existingSecret: keycloak-db        # key: password
  urlProperties: "?sslmode=require"

networkPolicy:
  monitoringNamespace: monitoring
```

```bash
helm upgrade --install keycloak ./keycloak-stack -n identity -f values-prod.yaml
```

---

## 3. How the pieces fit — explained

### 3.1 The existing gateway and the VirtualService

The chart **never creates a Gateway**. Your `key-gate` Gateway already owns a listener (port 443,
TLS credential, allowed hosts). A `VirtualService` is the only thing needed to say *"when
traffic for `keycloak.example.com` arrives on that gateway, send it to this Service."*

```yaml
spec:
  hosts: [keycloak.example.com]          # must be covered by the Gateway's hosts
  gateways: [istio-system/key-gate]      # namespace/name — cross-namespace reference
  http:
  - match: [{uri: {prefix: "/"}}]
    route:
    - destination:
        host: <release>-keycloak.<ns>.svc.cluster.local   # FQDN avoids ambiguity
        port: {number: 8080}
    timeout: 60s
    retries: {attempts: 2, perTryTimeout: 15s, retryOn: connect-failure,...}
    headers: {response: {set: {Strict-Transport-Security: ...}}}
```

Why these choices:

* **FQDN destination** – short names resolve relative to the VirtualService namespace, which
  silently breaks if someone copies the resource elsewhere.
* **`retryOn` without `5xx`** – Keycloak login POSTs are not idempotent; retrying a 500 could
  double-submit. We only retry connection-level failures.
* **60 s timeout** – admin-console bulk operations and first-login realm imports exceed Istio's
  default 15 s.
* **`blockAdminConsole`** – prepends a route for `/admin` that returns 403 via `fault.abort`.
  Istio evaluates routes in order, so the block comes first. Reach the console through
  port-forward or a second internal host (`keycloak.hostnameAdmin`).
* **HSTS / nosniff headers** are set at the edge, which is where TLS terminates.

### 3.2 DestinationRule

Client-side policy for calls *to* Keycloak (the gateway's Envoy honours it):

* **Consistent-hash on `AUTH_SESSION_ID`** – Keycloak's upstream recommendation. The
  authentication session lives in Infinispan and is replicated, but replication is async;
  stickiness removes the race where a browser's second request lands on a replica that has not
  received the session yet.
* **Outlier detection** – ejects a replica that returns 5 consecutive 5xx for 30 s, so a pod
  stuck mid-GC or mid-migration stops receiving logins.
* **No `tls:` block** – Istio auto-mTLS already negotiates mTLS to sidecar-enabled workloads;
  hard-coding `ISTIO_MUTUAL` only causes outages when a pod temporarily lacks a sidecar.

### 3.3 PeerAuthentication (mTLS)

Two **workload-scoped** policies (`selector.matchLabels`) set `mtls.mode: STRICT` for Keycloak
and Postgres only — a namespace-wide policy would silently change behaviour for unrelated
workloads. Two ports are exempted via `portLevelMtls`:

| Port | Mode | Why |
|---|---|---|
| 9000 (management) | PERMISSIVE | Prometheus and the `helm test` pod have no sidecar. Only health and metrics live here. |
| 7800 (JGroups) | DISABLE | Envoy is bypassed for this port (see 3.5), so it can't enforce mTLS. Protected by NetworkPolicy instead. |

### 3.4 AuthorizationPolicy (opt-in)

Identity-based L7 allow-list built on the SPIFFE identities mTLS gives you:

* Keycloak `:8080` ← only `cluster.local/ns/istio-system/sa/<gateway-sa>`
* Keycloak `:9000` ← `GET` from anyone (scrapers have no sidecar identity; NetworkPolicy gates it)
* Postgres `:5432` ← only Keycloak's ServiceAccount

It is **off by default** because the gateway's ServiceAccount name varies between Istio
installs; get yours with
`kubectl -n istio-system get deploy -l istio=ingressgateway -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}'`.

### 3.5 Keycloak clustering on Istio

Keycloak replicates sessions through Infinispan/JGroups on TCP 7800. Envoy intercepting that
port causes split-brain and `FD_SOCK` timeouts, so the chart:

1. Annotates pods with `traffic.sidecar.istio.io/exclude{In,Out}boundPorts: "7800,57800"`.
2. Sets `-Djgroups.bind_addr=$(POD_IP)` so JGroups advertises the real pod IP, not loopback.
3. Uses `KC_CACHE_STACK=jdbc-ping` (Keycloak 26 default) — members discover each other through
   a table in Postgres; no DNS or Kubernetes API access required. Switch to `kubernetes`
   (DNS_PING against the headless Service) if you prefer; the chart wires
   `-Djgroups.dns.query` automatically.
4. Allows 7800/57800 only from sibling Keycloak pods in NetworkPolicy.

### 3.6 Hostname and proxy headers

TLS terminates on the gateway, so Keycloak listens on plain HTTP inside the mesh (mTLS covers
the hop). For it to generate correct `https://` redirects and issuer URLs:

* `KC_HOSTNAME=https://<host>` (hostname v2, full URL)
* `KC_HOSTNAME_STRICT=true` — refuses requests for other hosts (Host-header injection guard)
* `KC_PROXY_HEADERS=xforwarded` — trust `X-Forwarded-For/Proto/Host` set by the gateway
* `KC_HTTP_ENABLED=true`

### 3.7 Health, metrics and probes

Keycloak ≥25 serves `/health/*` and `/metrics` on a **separate management port (9000)**, so they
are never exposed through the VirtualService (which only routes to 8080).

* `startupProbe` → `/health/started`, up to 5 min (DB migrations on upgrade).
* `livenessProbe` → `/health/live`; `readinessProbe` → `/health/ready` (includes DB check).
* `preStop: sleep 10` + `maxUnavailable: 0` give Envoy and kube-proxy time to drain endpoints
  before the JVM exits — no 503s during rollouts.

### 3.8 Secrets

* `ks.stablePassword` returns, in order: the value you set → the value already stored in the
  live Secret (via `lookup`) → a new `randAlphaNum 32`. A generated password therefore survives
  `helm upgrade`; it does **not** survive `helm template`/`--dry-run` (lookup is empty), which
  is expected.
* `checksum/secret` pod annotation rolls the pods when a chart-managed secret changes.
* `KC_BOOTSTRAP_ADMIN_*` only creates the admin on an **empty** database. Rotating it later
  must be done in the Keycloak UI/API; the env var is ignored afterwards.
* Prefer `existingSecret` + an external secrets operator in production so passwords never
  pass through Helm release history (which is stored in-cluster as a Secret, readable by
  anyone with `get secrets`).

### 3.9 The bundled PostgreSQL

Deliberately simple and honest about what it is: **one** StatefulSet pod, one PVC.

* `PGDATA` in a sub-directory (volumes with `lost+found` break `initdb`).
* `--data-checksums` to detect bit-rot.
* `readOnlyRootFilesystem: true` with `emptyDir` for `/var/run/postgresql` and `/tmp`.
* `persistentVolumeClaimRetentionPolicy: Retain` — `helm uninstall` keeps your data.
* `max_connections=200`: Keycloak's pool defaults to 100 per pod; size this to
  `replicas × 100 + headroom` or lower `KC_DB_POOL_MAX_SIZE` via `extraEnv`.
* Port named `tcp-postgresql` so Istio treats it as opaque TCP.

**There is no replication, no backup, no PITR.** For anything that matters, set
`postgresql.enabled=false` and point `externalDatabase` at CloudNativePG, Crunchy, RDS, etc.

### 3.10 NetworkPolicy

Ingress-only, so sidecars keep their egress to `istiod:15012`, DNS and external IdPs:

| Target | Allowed from | Port |
|---|---|---|
| Keycloak | Istio ingress-gateway pods (namespace + pod selector) | 8080 |
| Keycloak | Sibling Keycloak pods | 7800, 57800 |
| Keycloak | Same release pods, `monitoringNamespace` | 9000 |
| Keycloak / Postgres | `istio-system`, `monitoringNamespace` | 15020, 15021 (Envoy health/metrics) |
| Postgres | Keycloak pods | 5432 |

### 3.11 PDB and HPA

* PDB only renders when effective replicas > 1 — a `minAvailable: 1` PDB on a single replica
  blocks every `kubectl drain`.
* HPA scale-down is throttled (1 pod / 2 min, 5-min stabilisation) so Infinispan has time to
  rebalance session ownership.
* `topologySpreadConstraints` on `kubernetes.io/hostname` by default; add
  `topology.kubernetes.io/zone` for multi-AZ.

---

## 4. Values reference (abridged — every key is commented in `values.yaml`)

| Key | Default | Notes |
|---|---|---|
| `istio.gateway.name` / `.namespace` | `key-gate` / `istio-system` | The existing Gateway to attach to. |
| `istio.hosts` | `[keycloak.example.com]` | Public hostnames; validated as DNS names. |
| `istio.virtualService.prefixes` | `["/"]` | Match prefixes; use `/auth` with `keycloak.httpRelativePath=/auth`. |
| `istio.virtualService.blockAdminConsole` | `false` | 403 for `/admin` at the edge. |
| `istio.destinationRule.sessionAffinity.*` | on, `AUTH_SESSION_ID` | Sticky sessions. |
| `istio.peerAuthentication.mode` | `STRICT` | `PERMISSIVE` while migrating a brownfield namespace. |
| `istio.authorizationPolicy.enabled` | `false` | Identity allow-list; set the gateway principal first. |
| `istio.sidecar.excludeJGroupsPorts` | `true` | Required for >1 replica. |
| `keycloak.replicaCount` | `1` | ≥2 for HA (enables PDB). |
| `keycloak.args` | `["start"]` | `["start","--optimized"]` with a pre-built image. |
| `keycloak.hostname` | `https://<first host>` | Public URL (hostname v2). |
| `keycloak.hostnameAdmin` | `""` | Separate admin URL. |
| `keycloak.admin.existingSecret` | `""` | Keys `username`/`password` (configurable). |
| `keycloak.cache.stack` | `jdbc-ping` | or `kubernetes`. |
| `keycloak.features` | `[]` | e.g. `token-exchange`. |
| `keycloak.extraEnv` | `[]` | Any `KC_*` option not modelled. |
| `keycloak.autoscaling.*` | off | CPU/memory HPA. |
| `postgresql.enabled` | `true` | `false` ⇒ `externalDatabase.host` required (schema-enforced). |
| `postgresql.auth.existingSecret` | `""` | Key `password` (configurable). |
| `postgresql.persistence.retentionPolicy.whenDeleted` | `Retain` | Keep data on uninstall. |
| `externalDatabase.urlProperties` | `""` | e.g. `?sslmode=require`. |
| `networkPolicy.ingressGateway.*` | `istio-system`, `istio: ingressgateway` | Where the gateway pods live. |
| `networkPolicy.monitoringNamespace` | `""` | Allow scraping of :9000. |

---

## 5. Validate before you install

```bash
helm lint ./keycloak-stack
helm lint ./keycloak-stack --set postgresql.enabled=false        # schema should FAIL: host required
helm template keycloak ./keycloak-stack -n identity | kubectl apply --dry-run=server -f -
istioctl analyze -n identity          # after install: catches gateway/host mismatches
```

---

## 6. Best practices baked in (and the ones left to you)

### 6.1 Security
- Non-root, no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp on every container.
- No ServiceAccount token mounted (`automountServiceAccountToken: false`) — Keycloak never calls the Kubernetes API.
- mTLS STRICT + (optional) identity-based AuthorizationPolicy + NetworkPolicy = three independent layers.
- Management port never reachable from the internet; admin console can be blocked at the edge.
- `KC_HOSTNAME_STRICT=true` prevents Host-header spoofing of issuer URLs.
- **You should**: terminate TLS on `key-gate` with a cert from cert-manager, run `kube-bench`/Kyverno/Gatekeeper against the rendered manifests, and pin images by digest in `keycloak.image.tag` (`26.0.7@sha256:…`).

### 6.2 Reliability
- Rolling updates with `maxUnavailable: 0`, `preStop` drain, startup probe tolerant of migrations.
- Sticky sessions + Infinispan replication; HPA scales down slowly; PDB when it makes sense.
- Generated passwords are stable across upgrades; PVC retained on uninstall.
- **You should**: run ≥2 replicas across zones, move the database to an operator/managed service with backups, and test `helm rollback` — Keycloak migrations are forward-only, so pair a Keycloak major upgrade with a DB snapshot.

### 6.3 Build an optimized image (recommended for production)

`kc.sh start` without `--optimized` rebuilds Quarkus at every pod start (30–60 s) and needs a
writable `/opt/keycloak`. Bake the build once:

```dockerfile
FROM quay.io/keycloak/keycloak:26.0.7 AS builder
ENV KC_DB=postgres KC_HEALTH_ENABLED=true KC_METRICS_ENABLED=true KC_CACHE=ispn
# add KC_FEATURES=... here if you use feature flags
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.0.7
COPY --from=builder /opt/keycloak/ /opt/keycloak/
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
```

Then set `keycloak.args: ["start","--optimized"]`, point `keycloak.image` at it, and flip
`containerSecurityContext.readOnlyRootFilesystem: true`. Build-time options (`KC_DB`,
`KC_FEATURES`, `KC_HEALTH_ENABLED`, `KC_METRICS_ENABLED`, `KC_CACHE*`) must match between the
image and `values.yaml`; runtime options (hostname, DB URL, credentials, proxy headers) stay as env.

### 6.4 Observability
- `prometheus.io/*` pod annotations on the management port; set `networkPolicy.monitoringNamespace`.
- Istio gives you L7 telemetry for free because the Service port is named `http`.
- Set `keycloak.logLevel` and add `KC_LOG=console KC_LOG_CONSOLE_OUTPUT=json` via `extraEnv` for structured logs.

### 6.5 Operations
- Everything is one release: `helm upgrade --install` is idempotent; `helm test` verifies readiness.
- The schema rejects unknown keys (`additionalProperties: false`), so a mistyped value is a hard error.
- `commonLabels`/`commonAnnotations` for cost-allocation or Argo CD / Flux ownership labels.

---

## 7. Troubleshooting

| Symptom | Check |
|---|---|
| 404 from the gateway | Host not in `key-gate`'s `servers[].hosts`; `istioctl analyze` reports this. |
| Redirect loop / `http://` URLs | `keycloak.hostname` wrong or gateway not setting `X-Forwarded-Proto`. |
| "Invalid parameter: redirect_uri" after enabling `blockAdminConsole` | Admin console must be opened via `hostnameAdmin` or port-forward, not the public host. |
| Replicas don't form a cluster | Confirm the exclude-ports annotation landed (`kubectl get pod -o yaml`), NetworkPolicy allows 7800, and `JGROUPS` logs show `view: [...]` with N members. |
| `helm test` fails but pods are Ready | NetworkPolicy: the test pod carries `app.kubernetes.io/instance` so it's allowed; ensure no other deny-all policy in the namespace. |
| Postgres CrashLoop on first start | PVC pre-populated or wrong `fsGroup`; look for `initdb: directory exists but is not empty`. |
| Upgrade pending forever | Startup probe exhausted during a long migration — raise `keycloak.probes.startup.failureThreshold`. |
