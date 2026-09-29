Production Keycloak is not “practice checkout.” It is a real store with a real safe, a real warehouse (Postgres), a front door with a lock (HTTPS), and a manager office that is not on the public sidewalk.

`start-dev` + H2 is the cardboard register.  
`start` + Postgres + hostname + proxy + secrets is the real store.

Official production rules: use `start` (not `start-dev`), use a real database, set a public hostname, put a reverse proxy in front, and treat TLS as required.

---

## Picture the building

| Piece | Grocery | School | Production meaning |
|---|---|---|---|
| AKS | Shopping center | School campus | Kubernetes cluster |
| Namespace | One store suite | One building | `keycloak` |
| Postgres | Warehouse / inventory book | Permanent student records | Real database, not a scratch pad |
| Secrets | Store safe | Locked office drawer | Passwords never in values as plain text |
| Ingress + TLS | Locked front door + security camera | Main office door with badge reader | Public HTTPS |
| Keycloak pods | Cashiers | Teachers | App servers, 2+ so one can go home |
| Realm `grocery` | Loyalty club | — | Shopper logins |
| Realm `school` | — | Homeroom system | Student/teacher logins |
| Realm `master` | District manager | Superintendent | Admin only |
| Hostname | Official store URL | Official school URL | Printed on every login token |

---

## What “production” actually requires

Keycloak in `start` mode will refuse to boot unless you give it:

1. A **hostname** (or turn off hostname-strict — do not do that in prod).
2. **TLS on the pod** *or* `http-enabled=true` because the ingress/proxy terminates TLS.
3. A **real DB**. If you skip this, it quietly uses H2. That is worse than a crash.

Behind nginx / AGIC / Application Gateway, the usual safe combo is:

```text
start
hostname = https://sso.example.com
http-enabled = true          # only because the proxy does HTTPS
proxy-headers = xforwarded
db = postgres
health-enabled = true
metrics-enabled = true
```

`KC_PROXY=edge` is the old name. Prefer `KC_PROXY_HEADERS=xforwarded`.

---

## Architecture on AKS

```text
Mac / users
    |
 https://sso.yourdomain.com     (and maybe https://admin-sso.yourdomain.com)
    |
 Ingress (TLS cert from cert-manager or Azure)
    |  HTTP 8080 inside the cluster
 Keycloak pods (2+)
    |
 Azure Database for PostgreSQL  (best)
 or in-cluster PostgreSQL PVC   (ok for a first prod-like lab)
```

Cashiers never talk HTTPS to shoppers themselves. The mall door (ingress) does. Cashiers talk plain HTTP on the private hallway (`ClusterIP`). That is why `KC_HTTP_ENABLED=true` is OK **only** when the public door is HTTPS and the proxy overwrites `X-Forwarded-*` headers.

---

## 0. Names

```bash
export RG="rg-aks-keycloak-prod"
export LOC="eastus"
export AKS="aks-keycloak-prod"
export NS="keycloak"
export POSTGRES_RELEASE="keycloak-db"
export KC_RELEASE="keycloak"
export PUBLIC_HOST="sso.example.com"
export ADMIN_HOST="admin-sso.example.com"
```

Swap the hostnames for yours. Do not leave `example.com` if this will be a real URL.

---

## 1. Cluster (if you do not already have one)

Bigger than the 1-node toy cluster:

```bash
az group create --name "$RG" --location "$LOC"

az aks create \
  --resource-group "$RG" \
  --name "$AKS" \
  --node-count 3 \
  --node-vm-size Standard_D2s_v5 \
  --generate-ssh-keys \
  --enable-managed-identity \
  --enable-addons monitoring

az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing
kubectl create namespace "$NS"
```

Why 3 nodes: two Keycloak cashiers + one Postgres (if in-cluster) + room for ingress.

---

## 2. Secrets first (the safe)

Never put production passwords in Git.

```bash
# Admin (principal / store manager) — first boot only
kubectl -n "$NS" create secret generic keycloak-admin \
  --from-literal=username=admin \
  --from-literal=password="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | kubectl apply -f -

# Postgres user
kubectl -n "$NS" create secret generic keycloak-db-auth \
  --from-literal=postgres-password="$(openssl rand -base64 24)" \
  --from-literal=password="$(openssl rand -base64 24)" \
  --from-literal=username=keycloak \
  --from-literal=database=keycloak \
  --dry-run=client -o yaml | kubectl apply -f -
```

Read them later only when you need them:

```bash
kubectl -n "$NS" get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n "$NS" get secret keycloak-db-auth -o jsonpath='{.data.password}' | base64 -d; echo
```

Grocery: PIN is in the safe.  
School: locker combo is in the office, not on the locker.

---

## 3. PostgreSQL (the warehouse)

H2 is a napkin. Production needs a bound notebook.

### Option A — in-cluster Postgres (lab / small prod)

Bitnami chart names change; pin a version you trust and use an existing secret.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm upgrade --install "$POSTGRES_RELEASE" bitnami/postgresql \
  --namespace "$NS" \
  --set auth.username=keycloak \
  --set auth.database=keycloak \
  --set auth.existingSecret=keycloak-db-auth \
  --set primary.persistence.enabled=true \
  --set primary.persistence.size=20Gi \
  --set primary.resources.requests.cpu=250m \
  --set primary.resources.requests.memory=512Mi
```

In-cluster service DNS is usually:

```text
keycloak-db-postgresql.keycloak.svc.cluster.local
```

Confirm:

```bash
kubectl -n "$NS" get svc,pvc
```

### Option B — Azure Database for PostgreSQL (real production)

Create Flexible Server in Azure, private access if you can, then:

```text
database.hostname: myserver.postgres.database.azure.com
database.port: 5432
database.username: keycloak
database.database: keycloak
database.existingSecret: keycloak-db-auth
```

Turn on SSL (`KC_DB_SSLMODE=require` or `verify-full` with a CA). Treat this like a bank vault, not a hallway closet.

---

## 4. Realm files (homerooms / loyalty clubs)

Production still can import realms on first start. After that, change realms in the admin UI or a GitOps job — do not keep re-importing and wiping users.

`grocery-realm.json`

```json
{
  "realm": "grocery",
  "enabled": true,
  "displayName": "Corner Grocery",
  "registrationAllowed": false,
  "loginWithEmailAllowed": true,
  "bruteForceProtected": true,
  "clients": [
    {
      "clientId": "checkout-app",
      "enabled": true,
      "publicClient": true,
      "redirectUris": ["https://shop.example.com/*"],
      "webOrigins": ["https://shop.example.com"],
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false
    }
  ]
}
```

`school-realm.json`

```json
{
  "realm": "school",
  "enabled": true,
  "displayName": "Lincoln Middle School",
  "registrationAllowed": false,
  "loginWithEmailAllowed": true,
  "bruteForceProtected": true,
  "clients": [
    {
      "clientId": "homework-portal",
      "enabled": true,
      "publicClient": true,
      "redirectUris": ["https://portal.school.example.com/*"],
      "webOrigins": ["https://portal.school.example.com"],
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false
    }
  ]
}
```

Load them:

```bash
kubectl -n "$NS" create secret generic keycloak-realms \
  --from-file=grocery-realm.json \
  --from-file=school-realm.json \
  --dry-run=client -o yaml | kubectl apply -f -
```

`--import-realm` only reads `*.json` in `/opt/keycloak/data/import`. Do not put passwords for real people in those JSON files.

---

## 5. Production `keycloak-prod-values.yaml`

Line-by-line after the file.

```yaml
# ---- how many cashiers / teachers ----
replicas: 2

image:
  repository: quay.io/keycloak/keycloak
  pullPolicy: IfNotPresent

# Production start. Not start-dev.
command:
  - "/opt/keycloak/bin/kc.sh"
  - "start"
  - "--http-port=8080"
  - "--hostname=https://sso.example.com"
  - "--hostname-admin=https://admin-sso.example.com"
  - "--hostname-strict=true"
  - "--proxy-headers=xforwarded"
  - "--http-enabled=true"
  - "--health-enabled=true"
  - "--metrics-enabled=true"
  - "--import-realm"

# Chart maps these to KC_DB_* 
dbchecker:
  enabled: true

database:
  vendor: postgres
  hostname: keycloak-db-postgresql.keycloak.svc.cluster.local
  port: 5432
  username: keycloak
  database: keycloak
  existingSecret: keycloak-db-auth
  existingSecretKey: password

# Serve at / not /auth (Quarkus default is /)
http:
  httpEnabled: true
  relativePath: "/"

# Old chart proxy block — keep aligned with --proxy-headers
proxy:
  enabled: true
  mode: edge

cache:
  stack: jdbc-ping

service:
  type: ClusterIP
  httpPort: 80
  httpsPort: 8443

# Public front door
ingress:
  enabled: true
  ingressClassName: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-buffer-size: "128k"
    nginx.ingress.kubernetes.io/proxy-buffering: "on"
  rules:
    - host: sso.example.com
      paths:
        - path: /
          pathType: Prefix
    - host: admin-sso.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts:
        - sso.example.com
        - admin-sso.example.com
      secretName: keycloak-tls

resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: "2"
    memory: 2Gi

extraEnv: |
  - name: KC_BOOTSTRAP_ADMIN_USERNAME
    valueFrom:
      secretKeyRef:
        name: keycloak-admin
        key: username
  - name: KC_BOOTSTRAP_ADMIN_PASSWORD
    valueFrom:
      secretKeyRef:
        name: keycloak-admin
        key: password
  - name: KC_DB_SSLMODE
    value: disable
  - name: KC_LOG_LEVEL
    value: INFO
  - name: KC_HTTP_MAX_QUEUED_REQUESTS
    value: "1000"
  - name: JAVA_OPTS_APPEND
    value: >-
      -XX:MaxRAMPercentage=75.0
      -Djgroups.dns.query={{ include "keycloak.fullname" . }}-headless

extraVolumes: |
  - name: realm-import
    secret:
      secretName: keycloak-realms

extraVolumeMounts: |
  - name: realm-import
    mountPath: /opt/keycloak/data/import
    readOnly: true
```

If you use Azure Database for PostgreSQL with SSL, change:

```yaml
  - name: KC_DB_SSLMODE
    value: require
```

Do **not** set `KC_HTTP_ENABLED` again in `extraEnv` if `http.httpEnabled: true` already does it. That was the duplicate-key error.

---

## 6. Line-by-line: why each production setting exists

**`replicas: 2`**  
Two cashiers. One can restart; shoppers still check out. One replica is a single point of failure.

**`command: start`**  
Production profile. Theme cache on, HTTP off unless you turn it on, hostname required, no H2-as-a-plan.

**`--hostname=https://sso.example.com`**  
Printed on login tokens as the issuer. Wrong hostname = apps reject logins. Grocery: the receipt must show the real store name, not “localhost.”

**`--hostname-admin=...`**  
Manager office on a different URL. Public shoppers use `sso`; staff use `admin-sso`. You can later block `/admin` on the public host at the ingress.

**`--hostname-strict=true`**  
Do not accept random Host headers. The door guard checks the name on the badge.

**`--proxy-headers=xforwarded`**  
Ingress says “this request was HTTPS from sso.example.com.” Without this, Keycloak thinks it is `http://10.x.x.x:8080` and login redirects break.

**`--http-enabled=true`**  
Allowed because TLS dies at ingress. If you skip the proxy and expose the pod raw, you must give Keycloak real certs instead.

**`--health-enabled=true` / `--metrics-enabled=true`**  
School nurse and attendance sheet. The chart probes `/health/live` and `/health/ready` on the management port.

**`--import-realm`**  
On boot, read the backpack of JSON realms. First day of school only, then stop relying on it for daily changes.

**`database.*` + `existingSecret`**  
Warehouse address and the key from the safe. Chart turns this into `KC_DB`, `KC_DB_URL`, `KC_DB_USERNAME`, `KC_DB_PASSWORD`.

**`dbchecker.enabled: true`**  
A tiny sidecar waits until Postgres answers before Keycloak starts. Do not let the cashier open before the warehouse door.

**`http.relativePath: "/"`**  
This chart’s default is `/auth` (old WildFly habit). Modern Keycloak lives at `/`. Set this or every URL becomes `https://sso.example.com/auth/...` by surprise.

**`cache.stack: jdbc-ping`**  
Cashiers leave notes in a Postgres table (`jgroups_ping`) so they find each other. Default on current Keycloak. Better than hoping DNS gossip works.

**`ingress` + `tls` + cert-manager**  
Public locked door and a real certificate. `proxy-buffer-size: 128k` avoids 502s on the admin UI.

**`resources`**  
A lunch box size so the node scheduler knows this is not a 64 MB toy. Keycloak likes memory.

**`KC_BOOTSTRAP_ADMIN_*` from Secret**  
Creates the first principal. After first successful start, those env vars do not reset the password every time.

**`KC_HTTP_MAX_QUEUED_REQUESTS`**  
If the line is too long, say 503 instead of melting. Official prod guidance.

**`JAVA_OPTS_APPEND` + `MaxRAMPercentage`**  
Use most of the container memory. `jgroups.dns.query` is the walkie-talkie name of the headless Service.

**realm volume mount**  
Unzips the Secret into `/opt/keycloak/data/import`. Read-only so a pod cannot rewrite the roster.

---

## 7. Install

```bash
helm repo add codecentric https://codecentric.github.io/helm-charts
helm repo update

# edit hosts in the values file first
helm upgrade --install "$KC_RELEASE" codecentric/keycloakx \
  --namespace "$NS" \
  --create-namespace \
  -f keycloak-prod-values.yaml
```

Watch:

```bash
kubectl -n "$NS" get pods,svc,ingress
kubectl -n "$NS" logs -l app.kubernetes.io/name=keycloakx -f
```

You want a log line like “Listening on” / profile prod, and pods Ready.

DNS:

```text
sso.example.com        -> ingress public IP
admin-sso.example.com  -> same IP
```

```bash
kubectl -n "$NS" get ingress
```

---

## 8. First login

1. Open `https://admin-sso.example.com`
2. User/password from secret `keycloak-admin`
3. Change that password immediately
4. Confirm realms `grocery` and `school` exist
5. Create a confidential client for any backend app (checkout API, gradebook API). Public clients are only for browser SPAs.

Issuer URLs apps will use:

```text
https://sso.example.com/realms/grocery
https://sso.example.com/realms/school
```

Discovery:

```text
https://sso.example.com/realms/grocery/.well-known/openid-configuration
```

---

## 9. Extra production settings worth adding later

**Pod anti-affinity** — do not put both cashiers on the same node.

```yaml
affinity: |
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: keycloakx
        topologyKey: kubernetes.io/hostname
```

**PDB** — during upgrades, keep at least one Ready.

```yaml
podDisruptionBudget:
  minAvailable: 1
```

**NetworkPolicy** — only ingress and your apps may talk to 8080. Nobody else in the cluster.

**Do not publish metrics publicly.** Keep `/metrics` on the management port and scrape with Prometheus inside the cluster.

**Admin path lock** on the public host (nginx snippet):

```yaml
nginx.ingress.kubernetes.io/server-snippet: |
  if ($host = "sso.example.com") {
    location ^~ /admin {
      return 404;
    }
  }
```

**Backups** — snapshot Postgres (Azure backup or `pg_dump`). Realms and users live in the DB, not in the pod.

**Do not `--import-realm` on every upgrade** if the JSON would reset users. After day one, drop `--import-realm` from `command` or use Keycloak’s import with override disabled.

**SMTP** in each realm (Realm settings → Email) so “forgot password” works.

**Brute force** is already on in the sample JSON. Keep it.

**Password policy** in each realm: length, not the word `password`, not the store name.

**Confidential clients** get a client secret from a Secret, same pattern as admin:

```yaml
# app reads this, Keycloak stores the hashed secret in DB after you paste it in the UI
kubectl -n app create secret generic checkout-oidc \
  --from-literal=client-id=checkout-api \
  --from-literal=client-secret="$(openssl rand -base64 32)"
```

**Azure identity** — for Java/Spring apps, point OIDC at the grocery or school realm issuer. That is the same Keycloak work you already sketched with OIDC/Keycloak.

---

## 10. Dev vs prod cheat sheet

| Setting | Practice store | Real store |
|---|---|---|
| Command | `start-dev` | `start` |
| Database | H2 in the pod | Postgres |
| Hostname | `localhost` | `https://sso.example.com` |
| Hostname strict | false | true |
| HTTP | wide open | only behind TLS proxy |
| Admin password | `admin` in values | Secret |
| Replicas | 1 | 2+ |
| Ingress | port-forward | TLS ingress |
| Cache | local | `jdbc-ping` / Infinispan |
| Health | optional | on |
| Import realms | every boot is fine | first boot, then stop |

---

## 11. Tear down (ignore missing)

```bash
helm uninstall "$KC_RELEASE" -n "$NS" || true
helm uninstall "$POSTGRES_RELEASE" -n "$NS" || true
kubectl delete namespace "$NS" --ignore-not-found
az aks delete -g "$RG" -n "$AKS" --yes --no-wait || true
az group delete -n "$RG" --yes --no-wait || true
```

---

## Common prod failures (plain English)

| What you see | What it means | Fix |
|---|---|---|
| `hostname is not configured` | Production `start` needs a public name | set `--hostname=https://...` |
| Admin UI blank / wrong redirect | Proxy headers missing | `--proxy-headers=xforwarded` and ingress forwards proto/host |
| Duplicate `KC_HTTP_ENABLED` | Chart + extraEnv both set it | set it in only one place |
| Pod crash, H2 warnings | No `database.vendor` | point at Postgres |
| 502 on `/admin` | nginx buffers too small | `proxy-buffer-size: 128k` |
| Tokens say `http://10.x` | Hostname/proxy not set | hostname + xforwarded |
| zsh `no matches found extraEnv[0]` | Mac globbed the brackets | use a values file |

That is a full production path on the same codecentric `keycloakx` chart you already used: Postgres, secrets, `start`, hostname, proxy headers, ingress TLS, 2 replicas, health, realm import, and a split public vs admin door.