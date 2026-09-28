# 01 · Step-by-step setup (one complete example, start to finish)

This is the "follow the recipe" chapter. Do it once end-to-end; the other chapters explain *why*.
Budget: **~30–40 minutes** of wall-clock time (most of it waiting for Azure) and roughly **$0.25–0.35 per hour**
while the cluster exists (3 small VMs + a load balancer). Run `scripts/99-destroy.sh` when you are done.

## Prerequisites (install once)

| Tool | Why | Install |
|------|-----|---------|
| `az` (Azure CLI ≥ 2.60) | talks to Azure | https://learn.microsoft.com/cli/azure/install-azure-cli |
| `kubectl` | talks to the cluster | `az aks install-cli` |
| `helm` (≥ 3.12) | installs Keycloak + ingress-nginx | https://helm.sh/docs/intro/install |
| `jq` | reads JSON in scripts | `apt install jq` / `brew install jq` |
| `envsubst` | fills `${VARIABLES}` in manifests | `apt install gettext-base` / `brew install gettext` |
| bash ≥ 4 | runs the scripts (macOS: `brew install bash`) | |

You also need an Azure subscription where you may create resource groups. **No Docker needed.**

Windows? Use WSL2 (Ubuntu) and install the tools inside it.

## Step 0 — choose your settings

Open `scripts/00-config.sh`. It is the only file you must edit. The important lines:

```bash
export LOCATION="eastus"                  # pick a region close to you
export KC_ADMIN_PASSWORD="Admin-ChangeMe-123!"
export DEMO_USER_PASSWORD="password123"   # every demo user
export ENABLE_TLS="false"                 # true = real https certificates (needs LETSENCRYPT_EMAIL)
```

You can also change a value from the terminal (this uses `sed` under the hood — see [doc 10](10-changing-settings.md)):

```bash
tools/set-config.sh LOCATION westeurope
tools/set-config.sh KC_ADMIN_PASSWORD 'Something-Long-4nd-Unique!'
```

Then check everything **before** touching Azure:

```bash
tools/local-check.sh
```

You should see a list of `PASS` lines (things it cannot check on your machine show as `SKIP`).

## Step 1 — the building: `scripts/01-create-cluster.sh` (≈ 8 min)

```bash
scripts/01-create-cluster.sh
```

What happens, in order:

1. `az login` if you are not logged in.
2. A **resource group** `freshmart-rg` — the cardboard box that holds everything (delete the box, everything is gone).
3. An **Azure Container Registry** (ACR) — the supply closet where the app images are stored. Registry names must be
   unique in the whole world, so the script makes one from your subscription id and saves it to
   `scripts/.generated.env`.
4. The **AKS cluster** with one small *system* node (the janitor's room: DNS, metrics…).
5. `kubectl` credentials so your laptop can talk to the cluster. It ends with `kubectl get nodes`.

> **Re-runnable:** every step first asks "does it already exist?". If a script dies halfway (network hiccup), just run it again.

## Step 2 — the rooms and the front door: `scripts/02-setup-nodes.sh` (≈ 5 min)

```bash
scripts/02-setup-nodes.sh
```

1. Adds a second **node pool** called `apps` (2 VMs, label `workload=apps`). System things stay in the system pool;
   our shops run here.
2. Installs **ingress-nginx** with Helm. This is the front door: one public IP, and it looks at the host name
   (`java.…`, `python.…`, `keycloak.…`) to send each visitor to the right pod.
3. Waits for Azure to give that door a public IP, then saves `INGRESS_IP` and `BASE_DOMAIN=<ip>.nip.io`.
   `nip.io` is a free trick: the name `java.20.1.2.3.nip.io` simply resolves to `20.1.2.3`.
4. If `ENABLE_TLS=true`: installs **cert-manager** and a Let's Encrypt issuer so every ingress gets a real certificate.

## Step 3 — the notebook: `scripts/03-install-postgres.sh` (≈ 1 min)

Creates namespace `data`, a Secret with the passwords, and a Postgres 16 **StatefulSet** (a pod with a disk that
survives restarts). The init script creates two databases: `keycloak` (for the front office) and `grocery`
(for both shops — they share the `activity_log` table on purpose so one notebook shows everything).

## Step 4 — the phone book: `scripts/04-install-openldap.sh` (≈ 1 min)

Creates namespace `identity` and an OpenLDAP pod seeded with three people (`alex.ldap`, `jordan.ldap`, `riley.ldap`)
and two LDAP groups (`cashiers`, `managers`). The seed file is `k8s/openldap/seed.ldif`.

## Step 5 — the front office: `scripts/05-install-keycloak.sh` (≈ 4 min)

1. Writes `helm/keycloak/values-generated.yaml` from your config (host name, passwords, secrets).
2. `helm lint` then `helm upgrade --install keycloak helm/keycloak -f values.yaml -f values-generated.yaml`.
3. Keycloak starts with `--import-realm`: it reads `helm/keycloak/realms/grocery-realm.json` (roles, groups,
   the three local users, the three clients) **on its very first start**.
4. Waits until the pod is healthy, then prints the admin console URL.

The chart is small on purpose — read `helm/keycloak/templates/deployment.yaml`; it is ~100 lines.

## Step 6 — connect the phone book: `scripts/06-configure-realm.sh` (≈ 1 min)

Uses `kcadm` (Keycloak's command-line admin tool, run *inside* the Keycloak pod) to:

1. add an **LDAP user federation** (the front office now also trusts the phone book),
2. add a **group mapper** (LDAP group `cashiers` ↔ Keycloak group `cashiers` → role `cashier`),
3. sync groups, then users. It ends by listing every user and where they come from.

## Step 7 — build the apps: `scripts/07-build-images.sh` (≈ 6 min)

`az acr build` sends each folder to Azure, builds the Docker image there and stores it in your registry.
Three images: `freshmart/java-store`, `freshmart/python-deli`, `freshmart/go-client`, all tagged `IMAGE_TAG` (`v1`).
`scripts/07-build-images.sh java` builds only one.

## Step 8 — open the shops: `scripts/08-deploy-apps.sh` (≈ 3 min)

Applies the manifests in `k8s/apps/` (after filling in the `${VARIABLES}` with `envsubst`), waits for both
deployments and prints the URLs:

```
  Keycloak admin console : http://keycloak.20.1.2.3.nip.io/admin/   (user: admin)
  Java store (Spring)    : http://java.20.1.2.3.nip.io
  Python deli (Flask)    : http://python.20.1.2.3.nip.io
```

Open the Java store, click **Log in**, sign in as `sam.shopper` / `password123`. Try the Office link — you get the
"different badge" page. Log out, log in as `morgan.manager` — the office opens and the notebook already shows your
first visit.

## Step 9 — send in the inspectors: `scripts/09-run-tests.sh` (≈ 4 min)

Runs three Kubernetes **Jobs** in namespace `testing` and prints their logs:

* **Go inspector** — 28 API checks with Bearer tokens (fast, strict).
* **curl inspector** — the same checks written with curl so you can read each HTTP call.
* **Playwright inspector** — a real (headless) Chromium logs in as each person and clicks around.

Exit code 0 means every door behaved. `scripts/09-run-tests.sh playwright` runs just one.

## Step 10 — look around: `scripts/10-status.sh`

Prints URLs, pods per namespace, ingresses and the user list. Handy after a coffee break.

## Step 99 — clean up: `scripts/99-destroy.sh`

Deletes the resource group (cluster, registry, IPs, disks — everything) and `scripts/.generated.env`. It asks
for confirmation. **This is what stops the bill.**

## Best practices baked in (and where to look)

* **Idempotent scripts** — run any script twice, nothing breaks (`scripts/lib/common.sh` helpers).
* **Secrets never in manifests** — they come from `00-config.sh` at apply time; the `.generated.env` file is git-ignored.
* **Health probes everywhere** — Kubernetes only sends traffic to pods that answer `/healthz` or `/actuator/health`.
* **Least privilege in the apps** — every door declares which roles open it; the default is "must be logged in".
* **Audit log** — every request is written to `activity_log`, including failures (status 401/403).
* **PKCE on browser logins** — an extra one-time secret protects the login code (see doc 04).

## What to try next

* Change a price as the manager, then look at the notebook.
* Run the [stocker-role tutorial](tutorials/tutorial-add-a-stocker-role.md).
* Flip `ENABLE_TLS=true`, set your email, run scripts 02, 05 and 08 again → https everywhere.
