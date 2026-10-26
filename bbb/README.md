# Big Bang Keycloak on kind (Docker) with Istio

Local, reproducible deployment of the [Big Bang Keycloak package](https://repo1.dso.mil/big-bang/product/packages/keycloak)
into a [kind](https://kind.sigs.k8s.io/) cluster, fronted by an Istio ingress gateway and reachable at
`http://localhost:8080`. Public images only — no Iron Bank (`registry1.dso.mil`) credentials needed.

```
http://localhost:8080
      │  kind extraPortMapping 8080 -> 30080
      ▼
istio-gateway/public-ingressgateway   (istio/gateway Helm chart, NodePort 30080/30443)
      │  Gateway (HTTP :80, hosts "*")
      ▼
VirtualService keycloak/keycloak      (hosts "*" -> keycloak-keycloak-http:80)
      │
      ▼
StatefulSet keycloak-keycloak         (Big Bang chart -> codecentric keycloakx -> quay.io/keycloak/keycloak)
      │  KC_DB_URL_HOST=keycloak-postgresql
      ▼
StatefulSet keycloak-postgresql  (Bitnami PostgreSQL subchart -> docker.io/bitnamilegacy/postgresql:17.6.0)
```

> **Scope:** this repo is a dev/demo/test setup. Section 5 explains what has to change for production HA, and
> section 6 covers upgrades. Nothing here (credentials, single replicas, legacy images) should go to production as-is.

---

## 1. Files

| File | Purpose |
|---|---|
| `deploy.sh` | One-shot installer: kind cluster → Istio (base, istiod, ingress gateway) → Gateway → clone chart → pre-flight `helm template` → Keycloak → VirtualService → verify. Also `--verify` and `--destroy`. |
| `values.yaml` | Helm values for the Big Bang Keycloak chart, tuned for kind. Documented in section 3. |
| `.work/` | Created by the script: the cloned chart (`.work/keycloak`) and the last rendered manifest (`.work/rendered.yaml`). Safe to delete. |

## 2. Requirements

### Tools (on the machine running `deploy.sh`)

| Tool | Why | Notes |
|---|---|---|
| Docker | kind runs Kubernetes nodes as containers | Docker Desktop / Engine; ~4 CPU, 6–8 GB RAM free is comfortable |
| `kind` | creates the cluster | v0.20+ |
| `kubectl` | applies Gateway/VirtualService, waits on rollouts | matching the kind node version ±1 minor |
| `helm` | installs Istio and the Keycloak chart | v3.12+ (chart uses `values.schema.json`, OCI deps) |
| `git` | clones the chart from repo1 | repo1 is public for anonymous HTTPS clone |
| `python3` + PyYAML | pre-flight duplicate-env check on the rendered manifests | `pip install pyyaml` |
| `curl` (optional) | end-to-end HTTP check in `verify` | skipped if missing |

### Network access

| Host | Used by | Purpose |
|---|---|---|
| `repo1.dso.mil` | git | Big Bang Keycloak chart source |
| `istio-release.storage.googleapis.com` | helm | Istio Helm charts |
| `quay.io` | kind node | `quay.io/keycloak/keycloak` image |
| `docker.io` | kind node | `bitnamilegacy/postgresql`, `istio/*` images |
| `registry1.dso.mil` (OCI) | helm, **only if** `chart/charts/` is missing | `bb-common` subchart dependency; Big Bang vendors it, so normally not needed |

### Host ports

`8080` and `8443` on the host are mapped by kind to NodePorts `30080`/`30443` of the Istio ingress gateway service.
Change with `HOST_HTTP_PORT` / `HOST_HTTPS_PORT` before the cluster is created (kind port mappings are immutable).

### Script environment variables

| Variable | Default | Meaning |
|---|---|---|
| `CLUSTER_NAME` | `bb-keycloak` | kind cluster name (`kubectl` context `kind-bb-keycloak`) |
| `NAMESPACE` | `keycloak` | Keycloak + Postgres namespace |
| `RELEASE` | `keycloak` | Helm release. The script passes `upstream.database.hostname=<RELEASE>-postgresql`, so renaming is safe |
| `CHART_REF` | `7.3.2-bb.2` | Git tag/branch of the package repo. `main` = latest |
| `ISTIO_VERSION` | *(latest)* | Pin for reproducibility, e.g. `1.27.1` |
| `ISTIO_NS` / `GATEWAY_NS` / `GATEWAY_NAME` | `istio-system` / `istio-gateway` / `public-ingressgateway` | Mirrors Big Bang naming so values written for BB (`istio-gateway/public-ingressgateway`) work unchanged |
| `ISTIO_INJECT` | `false` | `true` labels the namespace for sidecar injection (see 5.4) |
| `KC_ADMIN_USER` / `KC_ADMIN_PASSWORD` | `admin` / `password` | Bootstrap admin; injected with `--set-string` so they never live in `values.yaml` |
| `HOST_HTTP_PORT` / `HOST_HTTPS_PORT` | `8080` / `8443` | Host ports; also drives `KC_HOSTNAME` |

---

## 3. `values.yaml`, section by section

The Big Bang chart (7.3.x-bb.x) is a thin wrapper: Keycloak itself is the
[codecentric `keycloakx`](https://github.com/codecentric/helm-charts/tree/main/charts/keycloakx) chart nested under
**`upstream:`**, the database is the Bitnami PostgreSQL chart under **`postgresql:`**, and Istio/NetworkPolicy
resources come from the Big Bang **`bb-common`** library chart. The chart ships a `values.schema.json`, so unknown
top-level keys are rejected — which is why the pre-4.0-era `domain:`, `istio:` and `networkPolicies:` keys are absent.

### `global.domain`
Big Bang convention for the cluster domain. Set to `localhost`; only used when `bb-common.routes` is enabled.

### `bb-common` (disabled)
| Key | Value | Why |
|---|---|---|
| `istio.enabled` | `false` | Would create PeerAuthentication / AuthorizationPolicy / ServiceEntry objects that expect the full Big Bang Istio install |
| `networkPolicies.enabled` | `false` | kind's default CNI (kindnet) doesn't enforce NetworkPolicy anyway; enabling only adds objects to debug |
| `routes.inbound.keycloak` | `enabled: false`, pre-filled (`service: keycloak-keycloak-http`) | The Big Bang-native way to get a VirtualService. `deploy.sh` creates its own instead so the manifest is visible and host-independent. To switch: set `enabled: true` and delete the VirtualService block in `deploy.sh`. `hosts: ["*"]` because Istio expands a dot-less host like `localhost` to `localhost.keycloak.svc.cluster.local` |

### `bbtests.enabled: false`
Big Bang's Cypress/script test hooks need the `bbtests` image and a passthrough TLS gateway. Off.

### `upstream` — Keycloak
| Key | Value | Why |
|---|---|---|
| `replicas` | `1` | Dev. See 5.1 for HA |
| `image.repository` | `quay.io/keycloak/keycloak` | Public upstream image. The Iron Bank image (`registry1.dso.mil/ironbank/opensource/keycloak/keycloak`) uses the same version strings, so switching back is a one-line change plus a pull secret |
| `image.tag` | *(unset)* | Falls through to the chart's pinned app version (26.x). Pin it explicitly in anything you intend to upgrade deliberately |
| `command` / `args` | `kc.sh start` | Production mode (optimized build, strict defaults). `start-dev` disables caching and relaxes hostname checks; fine for dev but don't let dev-only behaviour hide config bugs |
| `proxy.enabled` / `proxy.mode` | `true` / `xforwarded` | Renders `KC_PROXY_HEADERS=xforwarded`: Keycloak trusts `X-Forwarded-*` from the Istio gateway. Replaces the removed `--proxy=edge` option (see 6.2) |
| `proxy.http.enabled` | `true` | Renders `KC_HTTP_ENABLED=true`; TLS terminates at the gateway (or nowhere, on this dev setup) |
| `cache.stack` | `default` | Renders `KC_CACHE=ispn` + `KC_CACHE_STACK=jdbc-ping`: cluster discovery through the database, no extra ports/DNS needed |
| `metrics.enabled` / `health.enabled` | `true` | `KC_METRICS_ENABLED` / `KC_HEALTH_ENABLED`; probes hit `/health/*` on the **management port 9000** |
| `extraEnv` | `KC_HOSTNAME_BACKCHANNEL_DYNAMIC`, `KC_LOG_LEVEL` | **Only** vars the chart doesn't already render. The chart emits `KC_HTTP_ENABLED`, `KC_PROXY_HEADERS`, `KC_CACHE*`, `KC_METRICS_ENABLED`, `KC_HEALTH_ENABLED`, `KC_DB*`, `KC_HTTP_RELATIVE_PATH` itself; repeating any of them makes the StatefulSet apply fail with *duplicate entries for key*. `deploy.sh`'s pre-flight catches this |
| `secrets.env.stringData` | hostname + admin creds | Becomes the `keycloak-keycloak-env` Secret, loaded via `envFrom`. Map keys override the chart's defaults of the same name (the chart's default `KC_HOSTNAME` is `keycloak.dev.bigbang.mil`). `KC_HOSTNAME` is a full URL (hostname **v2** syntax), `KC_HOSTNAME_STRICT=false` so `127.0.0.1` / `keycloak.localhost` also work |
| `database.*` | bundled Postgres | `hostname: keycloak-postgresql` — the Bitnami subchart names its Service `<release>-postgresql` (note: *not* `keycloak-keycloak-postgresql` as older Big Bang docs show; the pre-flight check verifies this against the rendered Services). For an external DB set `postgresql.enabled: false` and point these here (or use `database.existingSecret`) |
| `dbchecker.enabled` | `false` | An init container that waits for the DB. The `--wait` + startup probe already cover this on kind |
| `http.relativePath` | `/` | keycloakx defaults to `/auth` for WildFly-era compatibility; Keycloak itself has defaulted to `/` since the Quarkus distribution |
| `service.type` | `ClusterIP` | The Istio gateway owns the NodePort. For "no Istio" set `NodePort` + `httpNodePort: 30080` and point the kind mapping at it |
| `resources` | 0.5–2 CPU, 1–2 GiB | Keycloak 26 on an empty realm idles ~600 MiB; the JVM sizes its heap from the memory **limit** |
| `podSecurityContext` / `securityContext` | uid 1000, gid 0 | `quay.io/keycloak/keycloak` runs as 1000:0. The Iron Bank image and BB defaults use 2000; switch back together with the image |
| `podAnnotations` | exclude inbound 9000 | Keeps the Istio sidecar (if injected) away from the management port so kubelet probes aren't intercepted |

### `postgresql` — bundled Bitnami PostgreSQL
| Key | Value | Why |
|---|---|---|
| `enabled` | `true` | Single-primary StatefulSet. **Not HA** — see 5.2 |
| `image.*` | `docker.io/bitnamilegacy/postgresql:17.6.0` | Bitnami moved versioned public images to the frozen `bitnamilegacy` namespace in 2025 (see 6.3). The BB default is `registry1.dso.mil/ironbank/bitnami/postgres` |
| `global.security.allowInsecureImages` | `true` | The Bitnami chart refuses any image that isn't `docker.io/bitnami/*` unless this is set — required for both `bitnamilegacy` and Iron Bank |
| `global.postgresql.auth.*` | `keycloak/keycloak/keycloak` | Must match `upstream.database.*` |
| `primary.persistence` | 2 GiB PVC | kind's `standard` StorageClass (local-path). Data survives pod restarts, not `--destroy` |
| `primary.networkPolicy.enabled` | `false` | Same reason as above |

---

## 4. Day-to-day

```bash
./deploy.sh                       # full install (idempotent; re-run after editing values.yaml)
./deploy.sh --debug               # same, with bash xtrace and helm --debug
./deploy.sh --verify              # istiod, gateway, Gateway/VS objects, pod Ready, in-cluster + host HTTP 200
./deploy.sh --diagnose            # pods, per-container state/reason/exit code, events, logs (current + previous)
./deploy.sh --destroy             # delete the kind cluster (and all data)

kubectl -n keycloak get pods,svc,pvc
kubectl -n keycloak logs -f -l app.kubernetes.io/name=keycloakx
kubectl -n istio-gateway logs deploy/public-ingressgateway
helm -n keycloak get values keycloak        # effective values
helm -n keycloak history keycloak
```

Admin console: `http://localhost:8080/admin/` (`admin` / `password` unless overridden).
Browsers treat `localhost` as a secure context, so the admin console works over plain HTTP; `keycloak.localhost`
resolves in Chrome/Firefox without `/etc/hosts` edits.

### 4.1 What the script checks at each step

| Step | Check | Fails fast with |
|---|---|---|
| 1 prereqs | tools present, Docker running, `values.yaml` parses, host ports free | tool/port name |
| 2 kind | nodes Ready, a default StorageClass exists (Postgres PVC) | — |
| 3 Istio | istiod rolled out, `networking.istio.io/v1` CRDs registered | — |
| 4 gateway | gateway deployment rolled out, NodePort really is 30080, Gateway selector matches ≥1 pod | — |
| 5 chart | `chart/Chart.yaml` present, subcharts vendored (else `helm dependency build`) | — |
| 6 pre-flight | `helm template` with the *exact* values → schema errors; duplicate env keys; `KC_DB_URL_HOST` matches a rendered Service; every Secret/ConfigMap referenced by a volume or `envFrom` is rendered; **no `registry1.dso.mil` images**; images pulled on the host and loaded into kind | precise offending key/image |
| 7 install | `helm upgrade --install` **without `--wait`**, then a watcher prints `ready n/m` plus every init/main container state each 10 s and bails out immediately on `CrashLoopBackOff`, `ImagePullBackOff`, `ErrImagePull`, `CreateContainerConfigError`, `OOMKilled`, `Error` | full diagnostics |
| 8 route | Keycloak Service has endpoints before the VirtualService is created | — |
| 9 verify | in-cluster curl from the gateway pod to the Service (isolates Istio from kind port mapping), then host curl | diagnostics |

Any non-zero exit after the cluster exists triggers the same diagnostics dump (`--diagnose` runs it on demand).

### 4.2 Reading a failure

`helm upgrade --wait` only says *"StatefulSet/keycloak/keycloak-keycloak not ready … 1 pods have failed"*. The
diagnostics section tells you which of these it actually is:

| Container state in diagnostics | Meaning | Fix |
|---|---|---|
| `[init] … waiting/ImagePullBackOff` on an init container | chart default pulls `p1-keycloak-plugin` (or similar) from registry1 | `upstream.extraInitContainers: ""` (set), or add the pull secret + Iron Bank image |
| `[cont] keycloak waiting/ImagePullBackOff` | tag doesn't exist / registry unreachable | pin a real `upstream.image.tag`; step 6 pre-pull should already have caught it |
| `[cont] keycloak waiting/CrashLoopBackOff`, last exit **1** | Keycloak/JVM refused to start — read the *previous* log | typical: bad `JAVA_TOOL_OPTIONS` for this image (set to `""`), unknown `KC_*` option, hostname v2 syntax (`KC_HOSTNAME` must be a URL), `--import-realm` with no realm file |
| `… CrashLoopBackOff`, log says *Connection refused / password authentication failed* | DB not reachable or creds mismatch | `upstream.database.*` ≠ `postgresql.global.postgresql.auth.*`, or Postgres pod itself failing — check its block in the same dump |
| `[cont] keycloak running`, `ready=False`, restarts climbing, exit **137** | killed by the startup probe or OOM | raise `resources.limits.memory` / `startupProbe.failureThreshold`; probes target port **9000** and need `health.enabled: true` |
| `CreateContainerConfigError` | referenced Secret/ConfigMap missing | step 6 check should catch; otherwise a `--set` typo |
| Postgres pod `Pending` | PVC unbound | no default StorageClass (step 2 check) |
| Postgres `CrashLoopBackOff` after an upgrade | data dir from an older major | see 6.3 — never bump the Postgres major by changing the tag |

---

## 5. What production HA needs (and this setup lacks)

### 5.1 Keycloak

| Concern | Dev (this repo) | Production |
|---|---|---|
| Replicas | 1 | ≥ 2, ideally 3 across zones. Set `upstream.replicas` or `upstream.autoscaling` (HPA on CPU) |
| Spread | none | `upstream.affinity` with `podAntiAffinity` or `topologySpreadConstraints` on `topology.kubernetes.io/zone` |
| Disruption budget | none | `upstream.podDisruptionBudget: {minAvailable: 1}` (keycloakx supports it) |
| Cluster/cache | `jdbc-ping` (DB discovery) — fine for HA too | Keep `jdbc-ping` (default since 26.1) or `kubernetes` (DNS over the headless service). With Istio sidecars, exclude JGroups port 7800 from the mesh (`traffic.sidecar.istio.io/excludeInboundPorts: "7800,9000"`) or enable `KC_CACHE_EMBEDDED_MTLS_ENABLED` |
| Sessions | persistent user sessions (Keycloak 26 default) — restarts don't log users out | Keep enabled; size the DB for the `offline_*`/`user_session` tables. No sticky sessions needed |
| DB pool | defaults | `KC_DB_POOL_MIN_SIZE` / `KC_DB_POOL_MAX_SIZE` sized so `replicas × max ≤` Postgres `max_connections` |
| JVM | heap from limit | `JAVA_OPTS_KC_HEAP="-XX:MaxRAMPercentage=70"` (or explicit `-Xmx`), limits ≥ 2 GiB, requests = limits for predictable scheduling |
| Probes | chart defaults on :9000 | Keep; raise `startupProbe.failureThreshold` on slow nodes — first start of a new version runs schema migrations |
| TLS | none | Terminate at the gateway (Big Bang `public` gateway + cert-manager) **or** passthrough to Keycloak (`KC_HTTPS_CERTIFICATE_FILE`, BB `passthrough` gateway). Either way set `KC_HOSTNAME=https://…` and `KC_HOSTNAME_STRICT=true` |
| Hostname | `localhost` | Real FQDN, `KC_HOSTNAME_STRICT=true`, optionally `KC_HOSTNAME_ADMIN` on a separate, internal-only host |
| Secrets | plain text in values | External secret (`upstream.extraEnvFrom` → `secretRef`), SOPS/External Secrets; rotate `KC_BOOTSTRAP_ADMIN_*` after first login (it's a temporary bootstrap user in 26) |
| Images | public, floating | Iron Bank images, **pinned tags**, pull secret `private-registry`; Big Bang keeps the chart's `appVersion` in step with the IB tag |
| Big Bang integration | none | Deploy through the Big Bang umbrella (`addons.keycloak`), which brings the `public`/`passthrough` gateways, NetworkPolicies, AuthorizationPolicies, monitoring and the `p1-keycloak-plugin` |
| Multi-site | – | Two-site active/active needs external Infinispan + DB replication (Keycloak "multi-site" feature). Out of scope for most deployments |

### 5.2 PostgreSQL

The bundled Bitnami `postgresql` chart is a **single primary with a PVC**. It is not HA, it does not do automatic
failover, and (since the Bitnami catalog change) its public image is frozen. For production:

| Option | Notes |
|---|---|
| **Managed service** (RDS/Aurora, Cloud SQL, Azure Flexible Server) | Simplest HA + backups + major upgrades. Set `postgresql.enabled: false`, point `upstream.database.*` at it, use `database.existingSecret` |
| **Kubernetes operator** — [CloudNativePG](https://cloudnative-pg.io/), Crunchy PGO, Zalando | Primary + synchronous/async replicas, automatic failover, continuous WAL archiving + PITR to object storage, declarative major upgrades (CNPG ≥ 1.26 runs `pg_upgrade` for you). Keycloak connects to the operator's read-write service |
| Bitnami `postgresql-ha` (repmgr + pgpool) | Also moved to `bitnamilegacy`; not recommended for new deployments |

Whatever you pick: `max_connections` sized for `keycloak replicas × pool max + headroom`, a backup you have
actually restored once, and a `pg_dump` taken immediately before every Keycloak upgrade.

### 5.3 Istio

In this repo Istio is installed with the upstream Helm charts and one HTTP gateway. In Big Bang, use the
`istio-core` / `istio-gateway` packages: the `public` gateway with TLS from cert-manager, and the `passthrough`
gateway if Keycloak must own its certificate (required for client-cert/CAC auth). Then enable
`bb-common.istio.enabled`, `bb-common.networkPolicies.enabled` and the `bb-common.routes.inbound.keycloak` route
instead of the hand-written VirtualService.

### 5.4 Sidecar injection
`ISTIO_INJECT=true` injects a sidecar into the Keycloak pods. With it, keep `excludeInboundPorts: "9000"` (probes)
and add `7800` if you use JGroups clustering without `KC_CACHE_EMBEDDED_MTLS_ENABLED`, otherwise the mesh will
break cluster formation.

---

## 6. Upgrades

### 6.1 Rules that make upgrades boring
1. **Pin everything**: `CHART_REF`, `upstream.image.tag`, `postgresql.image.tag`, `ISTIO_VERSION`. Floating tags turn a routine `helm upgrade` into a surprise major upgrade.
2. **Separate the database lifecycle from the chart** (`postgresql.enabled: false` + external DB/operator). The chart's Postgres subchart is the hardest thing to upgrade (see 6.3) and the one you least want coupled to a Keycloak rollout.
3. **Back up the DB before every Keycloak minor/major** — schema migrations are one-way.
4. **Read the release-specific section** of the [Keycloak upgrading guide](https://www.keycloak.org/docs/latest/upgrading/) for *every* minor between your current and target version, not just the target. Breaking changes land in minors (25.0, 26.0, 26.1 …).
5. **Walk through minors you skipped** when the guide says so (e.g. 24 → 25 → 26, because 26 clears all caches and only 25+ can persist sessions first). For patch releases jumping is fine.
6. **First start with one replica**: the first node to start a new version runs the schema migration; scale to 1, roll, confirm `/health/ready`, then scale back up.
7. **Check rolling-update compatibility** (Keycloak ≥ 26.2):
   ```bash
   # on the OLD version/config
   kc.sh update-compatibility metadata --file=/tmp/kc-meta.json
   # with the NEW image/config
   kc.sh update-compatibility check --file=/tmp/kc-meta.json   # exit 0 = rolling OK, 3 = recreate (downtime)
   ```
   Cache/DB option changes, feature toggles like `persistent-user-sessions`, and any version change outside what the check allows require a *recreate* (all old nodes down before new ones start).
8. **Rebuild custom providers/themes** against the new version (e.g. Big Bang's `p1-keycloak-plugin` has its own version line per Keycloak major). Mismatched provider JARs are the most common post-upgrade failure.
9. **Diff before applying**: `helm diff upgrade` (plugin) or `helm template | diff` against `.work/rendered.yaml`.
10. **Rehearse on kind** with a `pg_dump` of production: this repo exists for exactly that.

### 6.2 Keycloak: what bit people on older releases → current

| From | Change | Impact / fix |
|---|---|---|
| ≤ 19 (WildFly) → 20+ (Quarkus) | Entire distribution replaced; WildFly `standalone.xml`, `/auth` prefix, `KEYCLOAK_USER` gone | Everything is `KC_*` env / `kc.sh` options. keycloakx chart keeps `http.relativePath: /auth` for old URLs; new deployments use `/` |
| 21 → 22 | Quarkus 3, Java 11 dropped (17+), Hibernate 6 | Custom providers compiled for Java 11 / Hibernate 5 break |
| 23 → 24 | `--proxy` deprecated for `--proxy-headers`; cookie/SameSite changes; new default cookie names; container JVM sizing changes; Java 21 added | Set `proxy.mode: xforwarded` (or `forwarded`) in the chart. Review memory limits |
| 24 → 25 | **Hostname v2 is the default** (`hostname-url`, `hostname-path`, `hostname-strict-https`, `hostname-admin-url` removed; `KC_HOSTNAME` takes a full URL; `KC_HOSTNAME_ADMIN` replaces the admin URL). **Health/metrics move to management port 9000**. Argon2 default hashing. `session_state` claim removed, `basic` scope added | Probes must target :9000 (keycloakx ≥ 2.3 does). Istio: exclude 9000 from the sidecar. `hostname:v1` feature exists only as a stop-gap. Clients relying on `session_state` need the `basic` scope |
| 25 → 26.0 | **`--proxy` removed** entirely. **`KEYCLOAK_ADMIN*` deprecated → `KC_BOOTSTRAP_ADMIN_*`** (bootstrap user is now temporary). **Persistent user sessions on by default** (sessions in DB). Infinispan marshalling switched to Protostream — **all caches cleared on upgrade**, so upgrade to 25 with persistent sessions first to keep logins. External Infinispan in single-site is unsupported. `cache*` options became runtime options. XA transactions default off. Keycloak JS no longer served by the server. Build-time option mismatches now abort startup | Set both admin var pairs during transition (this repo does). Expect larger DB (sessions). If `KC_CACHE`/`KC_CACHE_STACK` were baked into a custom optimized image, move them to runtime |
| 26.0 → 26.1 | `jdbc-ping` becomes the default cluster stack (was `udp`); more options moved to runtime | Clusters that relied on the implicit UDP/`kubernetes` stack now discover via the DB — simpler, but needs DB access from every node at startup |
| 26.1 → 26.2+ | `rolling-updates` feature + `update-compatibility` command; schema-migration index creation on large tables (> 300k rows) is **skipped and logged** for manual execution | Run the compatibility check in CI. After migrating big instances, grep logs for the SQL you must apply by hand |
| Big Bang chart 23/24.x-bb.* → 7.x-bb.* | Chart renumbered to track the keycloakx chart; Keycloak values moved under **`upstream:`**; Istio/NetworkPolicy keys moved to **`bb-common.*`**; `values.schema.json` rejects old top-level keys; `fullnameOverride` fixed at `keycloak-keycloak` | Re-nest your overrides. `helm template` first — the schema error is immediate and precise |

### 6.3 PostgreSQL: what bit people on older releases → current

| Topic | Problem | Mitigation |
|---|---|---|
| **Major version upgrades are not in-place** | Postgres on-disk format changes per major. A StatefulSet whose image goes 15 → 17 will **crash-loop** on the old data directory. The Bitnami image/chart does **not** run `pg_upgrade` for you | Either `pg_dumpall` → new cluster → restore (simple, needs a window), `pg_upgrade --link` in a job with both binaries, or an operator that does it declaratively (CloudNativePG ≥ 1.26 offline major upgrade). Never rely on the chart's `image.tag` bump |
| **EOL versions** | PG 12 EOL Nov 2024, **PG 13 EOL Nov 2025**, PG 14 EOL Nov 2026 — no more security patches | Current supportable targets: 16, 17 (this repo), 18. Keycloak 26 is tested with recent PG majors; check the Keycloak "supported platforms" page before pairing a brand-new major |
| **Bitnami catalog change (Aug–Sept 2025)** | `docker.io/bitnami/*` versioned tags were removed; only `latest` remains in the free catalog. Versioned images moved to **`bitnamilegacy/*`**, which is frozen (no CVE fixes). Charts pulling `bitnami/postgresql:16.x` suddenly failed to pull | Point `image.repository` at `bitnamilegacy/postgresql` **and** set `global.security.allowInsecureImages: true` (the chart refuses non-`bitnami/*` images otherwise). Treat it as a bridge; move to Iron Bank, an operator image, or the official `postgres` image + operator |
| **Bitnami chart value renames** | `postgresqlUsername/Password/Database` → `auth.*` / `global.postgresql.auth.*`; `persistence.mountPath` and `postgresqlDataDir` changed across chart majors (the BB chart overrides both) | Diff `helm show values` between chart versions before bumping the BB chart |
| **Password drift on re-install** | Bitnami generates a random password if none is set; a `helm uninstall`/`install` with the old PVC fails auth | Always set `global.postgresql.auth.password` (or an existing secret) explicitly — this repo does |
| **PVC + StatefulSet immutability** | Changing `volumeClaimTemplates` (size, storage class) is rejected by Kubernetes | Resize the PVC directly (if the StorageClass allows expansion) and keep values in sync, or migrate data |
| **Connection exhaustion after scaling Keycloak** | Each Keycloak replica opens its own pool (default max 100) | Raise `max_connections` or add PgBouncer/pgpool; set `KC_DB_POOL_MAX_SIZE` |
| **Keycloak 26 sessions in DB** | After 25 → 26 the DB grows and write load rises (every login is a row) | Size storage/IOPS, run `VACUUM`/autovacuum tuning, keep `offline_session` retention sane in realm settings |

### 6.4 A safe upgrade sequence (Keycloak and/or Postgres)

```
1. pg_dump / operator backup; note current chart + image versions (helm history, kubectl get sts -o yaml)
2. Read the upgrading guide for every Keycloak minor you are crossing; rebuild providers/themes
3. On kind: restore the dump, bump CHART_REF / tags in values.yaml, ./deploy.sh, ./deploy.sh --verify, log in, run smoke tests
4. If Postgres major changes: do the DB upgrade FIRST (dump/restore or operator), on the old Keycloak version; verify
5. Keycloak: scale to 1 replica -> helm upgrade -> wait for /health/ready (schema migration) -> scale up
   (>= 26.2 with same cache/db config: run update-compatibility check; exit 0 lets you skip the scale-down)
6. Verify: realm login, admin console, OIDC flow of one real client, metrics on :9000, logs free of
   "skipped index creation" SQL (apply it if present)
7. Keep the backup until the next successful backup after the upgrade
```

---

## 7. References

- Big Bang Keycloak package: <https://repo1.dso.mil/big-bang/product/packages/keycloak> · docs: <https://docs-bigbang.dso.mil/latest/packages/keycloak/>
- bb-common routes: <https://docs-bigbang.dso.mil/latest/library-charts/bb-common/docs/routes/>
- codecentric keycloakx chart: <https://github.com/codecentric/helm-charts/tree/main/charts/keycloakx>
- Keycloak upgrading guide (release-specific changes): <https://www.keycloak.org/docs/latest/upgrading/>
- Keycloak rolling updates / `update-compatibility`: <https://www.keycloak.org/server/update-compatibility>
- Keycloak hostname v2: <https://www.keycloak.org/server/hostname>
- Bitnami catalog change: <https://github.com/bitnami/charts/issues/35164>
- Bitnami legacy images: <https://hub.docker.com/r/bitnamilegacy/postgresql/tags>
- PostgreSQL versioning / EOL: <https://www.postgresql.org/support/versioning/>
- CloudNativePG: <https://cloudnative-pg.io/>
