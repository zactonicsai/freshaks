# Architecture and security review guide

**Purpose:** give a reviewer enough context to understand the chart, challenge its assumptions, and approve it **only for the correct environment**.

## What this chart does—and does not do

**It does:** deploy one Keycloak, one PostgreSQL StatefulSet, the two required internal Services plus the StatefulSet's headless Service, one Istio VirtualService, a separate realm-import subchart, and an optional Helm test Pod. It references Secrets created separately.

**It does not:** install Istio, create a Gateway automatically, provision DNS or a certificate, scale a database, handle PostgreSQL backups, guarantee HA, rotate existing admin passwords, reconcile an existing realm, enable network isolation rules, or guarantee zero-downtime Keycloak upgrades. Those are explicit follow-up architecture tasks.

## Section-by-section code explanation

### `Chart.yaml` and the local `realm` subchart

`apiVersion: v2` makes this a Helm 3 chart. `version` tracks changes to the **chart**, while `appVersion` identifies the Keycloak release. `dependencies` points at `file://charts/realm`, so it is vendor-local and reviewable. The `realm.enabled` condition allows the importer to be disabled. Avoid adding remote chart repositories if the deployment is air-gapped.

The subchart produces exactly one ConfigMap called `<helm-release>-realm`; the parent uses the same name in a `volumeMount`. This name contract is intentionally called out in both source files. Changing either helper name requires changing the other. The realm data is generated with `toPrettyJson` rather than manually inserting commas and quotes in templates.

The demo realm includes two simple roles, a public OIDC client for a local React-style SPA, **PKCE S256 required on the demo client**, exact development origins, registration disabled, and no predefined users or client secrets. For real use, enforce PKCE through broader client policies too, define actual redirect URIs, use your organization access model, and prohibit local HTTP.

### `values.yaml`, `values-local.yaml`, and `values.schema.json`

Most configurable settings live in `values.yaml`. `values-local.yaml` is a small overlay for a developer's cluster. This makes environment differences visible at review time instead of hiding them inside the templates.

The JSON schema validates common errors, including the fixed single replica constraint, valid database port, required hostname, and realm naming. Template-time checks also reject an external PostgreSQL configuration that omits `database.host`.

Use image **digest pins** for an audited production supply chain; version tags are readable local defaults, not immutable guarantees. Keep the Istio Gateway host, Keycloak advertised `hostname`, and browser port-forward port consistent: mismatched values can cause broken login redirects, origin errors, and invalid OIDC issuer values.

### `keycloak-deployment.yaml`

- `replicas: 1` and `strategy: Recreate`: keeps this lab simple and avoids overlapping, non-clustered Keycloak pods. It causes brief downtime on upgrades. Real HA requires an intentional clustering/cache and DB design.
- `KC_DB...`: tells Keycloak to use PostgreSQL instead of an embedded database. The password comes from `secretKeyRef`; Helm release metadata does not contain the plaintext password.
- `KC_BOOTSTRAP_ADMIN...`: references a separate Secret. Bootstrap is only useful for an initial admin; it is not a password rotation facility.
- `KC_HTTP_ENABLED=true`: allows HTTP on port 8080 behind Istio. **Production must terminate TLS at a trusted gateway or use stronger re-encryption.** The local example intentionally uses HTTP for host testing.
- `KC_HOSTNAME`: fixes the public URL, including scheme and host port. OIDC issuers and redirects rely on it.
- `KC_PROXY_HEADERS=xforwarded`: instructs Keycloak to read forwarded client headers. Only safe if ingress **overwrites** untrusted incoming `X-Forwarded-*` values. Restrict direct pod access where possible and consider trusted-proxy CIDRs.
- `KC_HTTP_MANAGEMENT_SCHEME=http` and `KC_HEALTH_ENABLED`: enable an independent HTTP management endpoint for probes on port 9000. `startupProbe` allows a longer first startup, `readinessProbe` gates traffic, `livenessProbe` restarts an unresponsive container. Only kubelet/pod networking should reach this port.
- `KC_CACHE=local`: matches the **single-instance-only** design. Do not increase replicas without a cache and discovery design.
- `automountServiceAccountToken: false`, `runAsNonRoot`/UID 1000, dropped capabilities, seccomp, and no privilege escalation: container hardening and removal of unneeded Kubernetes API credentials. `readOnlyRootFilesystem: false` is a conscious exception because the standard image writes during startup.
- Optional ConfigMap mount at `/opt/keycloak/data/import` plus `start --import-realm`: bootstraps a **missing** realm, not a drift-reconciler.

### `postgresql-statefulset.yaml`

StatefulSet gives the database a stable identity and a stable PersistentVolumeClaim (`data-<statefulset-name>-0`). The headless Service serves that identity; the regular ClusterIP Service is what Keycloak connects to. Only one database replica is configured: additional StatefulSet pods would not create safe PostgreSQL replication.

The database image runs as UID/GID 999. `fsGroup: 999` helps Kubernetes make PVC access possible without a root startup process on suitable storage drivers. Some CSI provisioners may require further setup; check volume ownership if PostgreSQL cannot start. `PGDATA` uses a subdirectory in the mounted volume to avoid filesystem-specific root directories. Password-based remote authentication uses SCRAM-SHA-256 during initial database initialization. `pg_isready` checks process readiness, not SQL application-level correctness.

`volumeClaimTemplates` creates persistent storage by default. **Changing database name, user, or password in Helm values after initialization does not migrate an existing PostgreSQL database.** Back up and execute an explicit migration or rotation plan. Turning persistence off opts into destructive, disposable `emptyDir` storage.

### `virtualservice.yaml`

The VirtualService attaches to an **existing** Istio Gateway (e.g. `istio-system/local-keycloak-gateway`) and sends requests for `keycloak.localhost` to `<service>.<namespace>.svc.cluster.local:8080`. The Gateway resource is the routing attachment; `istio-ingressgateway` is usually the Kubernetes Service to port-forward. They are different resources. The Gateway must permit the host, the ingress service must listen on port 80, and the host must reach the ingress Service from the desktop.

The URL `http://keycloak.localhost:18080` is appropriate only for loopback development. This chart never routes port 9000 through Istio. An in-cluster caller might still reach the Pod IP's management port unless network policies prevent it.

### `tests/oidc-smoke.yaml` and scripts

The Helm test Pod calls the internal discovery endpoint and expects HTTP 200. The Bash test then verifies the browser-style ingress route and compares the returned issuer to the configured public URL. Together these distinguish an application problem from an Istio routing problem. The test script protects against wrong-context deployment by requiring an exact `CONFIRM_CONTEXT` match. It does *not* perform a full OAuth code login, admin UI browser test, penetration test, data restore exercise, or upgrade/rollback test.

## Review checklist

| Area | Lab default | Review action before production |
| --- | --- | --- |
| Availability | 1 Keycloak + 1 PostgreSQL | Build tested HA, backup/restore, anti-affinity, disruption, failover |
| Edge transport | HTTP on host loopback | TLS certificates, HTTPS redirect, trusted proxy headers |
| Realm SSL | `sslRequired: none` | Change to `all`; migrate to HTTPS first |
| Image integrity | Versioned tags | Pin trusted digests, scan images, maintain patch schedule |
| Secrets | Precreated Kubernetes Secrets | Use external secret store + encryption at rest + RBAC + rotation |
| Database | StatefulSet + default StorageClass | Managed/HA DB, encrypted volumes/connections, PITR backups |
| Probes | Health on 9000 | Verify mesh probes, keep metrics/health private |
| Network | Internal Services, external VS | Apply namespace-scoped NetworkPolicy/AuthorizationPolicy after connectivity test |
| Runtime privileges | Non-root UIDs; no privilege escalation | Validate SCC/Pod Security, filesystem ownership and admission policies |
| Realm changes | Initial import only | Managed realm change API/reconciler with a versioned migration plan |
| Update process | `helm upgrade --atomic` | Run full staging tests, DB compatibility checks and recovery drill |
| Governance | Explicit env overlay | GitOps approvals, drift detection, audit/event logging, ownership |

## Suggested upgrade path

1. **Lab signoff:** run `scripts/lint.sh`, install on a disposable namespace, run `helm test`, verify Istio OIDC issuer and admin UI.
2. **Security signoff:** replace HTTP with HTTPS, enforce realm SSL, configure ingress header trust and network restrictions, pin image digests, create access policies.
3. **Data signoff:** select managed PostgreSQL or build replicated Postgres with disaster recovery; test backup/restore before any version changes.
4. **Identity signoff:** configure real realm/client settings and an explicit, safe live realm-change process; require code review for redirect URI changes.
5. **Operations signoff:** monitoring, alerts, capacity testing, certificate renewal, Keycloak clustering, rollout and incident response plans.

## Helpful troubleshooting commands

```bash
kubectl get gateways.networking.istio.io -A
kubectl -n identity-demo get virtualservices.networking.istio.io -o yaml
kubectl -n identity-demo get pods -o wide
kubectl -n identity-demo describe pvc
kubectl -n identity-demo describe deploy identity-keycloak-istio-stack-keycloak
kubectl -n identity-demo logs deploy/identity-keycloak-istio-stack-keycloak --tail=200
kubectl -n identity-demo logs sts/identity-keycloak-istio-stack-postgresql --tail=200
helm get values identity -n identity-demo
helm get manifest identity -n identity-demo
```

Common failure meanings:

- **`ImagePullBackOff`**: image registry inaccessible; mirror images when offline.
- **PostgreSQL `Pending`**: no working StorageClass, unbound PVC, or missing CPU/memory.
- **PostgreSQL permission denied**: PVC ownership incompatible with UID 999 / `fsGroup`.
- **Keycloak `CrashLoopBackOff`**: missing Secret key, DB unavailable, or image/startup mismatch. Read container logs.
- **Istio 404**: Gateway/VirtualService host mismatch or incorrect gateway reference.
- **Istio 503**: incorrect Service selector, no ready Keycloak endpoints, or mesh routing problem.
- **Wrong OIDC issuer**: `KC_HOSTNAME` differs from browser URL (including port/scheme).
- **Realm edit not applied**: expected one-time import behavior, not necessarily a Helm error.

All source claims should be compared against the official links collected in the README for the version being adopted. This review guide explains the *specific implementation* in this repository.
