# Upgrading Kubernetes on Azure without taking the service down

A complete, runnable example for Azure Kubernetes Service (AKS). You install a small but
realistic system with **old** versions of everything, and then upgrade every part to the
**newest** version while a probe measures what users would notice. Every step is one small
shell script, every command in it has a comment, and every step is written to a log.

| Part | Old version (installed) | Upgrade path | Newest version |
| --- | --- | --- | --- |
| Kubernetes (AKS) | 1.34 | 1.35 → 1.36 | 1.36 |
| Istio (ingress and egress) | 1.28.1 | 1.29.8 → 1.30.5 → 1.31.1 | 1.31.1 |
| Keycloak (single sign-on) | 24.0.5 | direct | 26.8.0 |
| PostgreSQL | 14.12 | new server next to the old one | 18.6 |
| Two Spring Boot apps | 1.0.0 | rolling update | 2.0.0 |

Versions are the ones current in October 2026. They live in one file,
[`config/versions.env`](config/versions.env) - change them there.

> **Read this first: what was and was not tested.**
> Everything here was linted, checked against schemas and run end to end against stand-in
> ("stub") versions of `az`, `kubectl`, `helm`, `curl` and `docker`. It has **not** been run
> against a real Azure subscription, and the Java apps were type-checked but not built into
> images. Treat the first real run as a test run, and read
> [What was tested](#what-was-tested-and-what-was-not) before you rely on it.

---

## Contents

1. [What you get](#what-you-get)
2. [The picture](#the-picture)
3. [Before you start](#before-you-start)
4. [Quick start](#quick-start)
5. [Folder layout](#folder-layout)
6. [Install: one script per action](#install-one-script-per-action)
7. [Upgrade: the safe order and why](#upgrade-the-safe-order-and-why)
8. [High availability: what is built in](#high-availability-what-is-built-in)
9. [What is NOT highly available here](#what-is-not-highly-available-here)
10. [Rollback at a glance](#rollback-at-a-glance)
11. [Logs: every step is written down](#logs-every-step-is-written-down)
12. [Test users and the login test](#test-users-and-the-login-test)
13. [Shared volumes and the NFS pod](#shared-volumes-and-the-nfs-pod)
14. [Istio: the way in and the way out](#istio-the-way-in-and-the-way-out)
15. [The two apps](#the-two-apps)
16. [Terraform version](#terraform-version)
17. [Destroy](#destroy)
18. [What was tested and what was not](#what-was-tested-and-what-was-not)
19. [Where to read next](#where-to-read-next)

---

## What you get

- **Shell scripts with `az`, `kubectl`, `helm` and `docker`** - more than 70, one action
  each, with a comment above every command. There are scripts to install, upgrade, roll back
  and destroy, plus an `-all` script per group that runs them in order.
- **Istio as the only way in and out.** An ingress gateway behind a static Azure public IP,
  an egress gateway for the one allowed external host, and strict mutual TLS between all pods.
- **Keycloak** with a ready-made realm, two OIDC clients and three test users.
- **PostgreSQL** as Keycloak's database, with its data on shared NFS storage.
- **Two Java Spring Boot apps** (Portal and Reports) that log in through Keycloak, share one
  login (single sign-on) and have a static HTML page styled with Tailwind CSS and plain
  JavaScript.
- **Shared volumes on NFS**: an NFS server pod on an Azure disk (or Azure Files, one setting).
- **A Terraform / OpenTofu version** of the same system in [`terraform/`](terraform/).
- **A tutorial** about the traps and about easy rollback:
  [`TUTORIAL-gotchas-and-rollback.md`](TUTORIAL-gotchas-and-rollback.md).

---

## The picture

```
                         Internet
                            |
                 static public IP (zone-redundant)
                            |
                 Azure Load Balancer (Standard)
                            |
        +-------------------v--------------------+
        |  Istio INGRESS gateway  (2+ pods)      |  TLS ends here, *.<ip>.nip.io
        +----+---------------+--------------+----+
             |               |              |           everything between pods:
             v               v              v           Istio sidecars + mutual TLS
        +---------+     +---------+    +----------+
        |  app1   |     |  app2   |    | Keycloak |  2 pods each
        | Portal  |     | Reports |    |   SSO    |
        +--+---+--+     +--+---+--+    +----+-----+
           |   |           |   |            |
           |   +-----+-----+   |            v
           |         |         |      +------------+      +---------------------+
           |         v         |      | PostgreSQL |----->| NFS volume: data    |
           |  NFS volume:      |      |  (1 pod)   |----->| NFS volume: backups |
           |  shared notes     |      +------------+      +---------------------+
           |                   |
           +---------+---------+
                     v
        +----------------------------------------+
        |  Istio EGRESS gateway  (2+ pods)       |  only api.ipify.org is allowed
        +-------------------+--------------------+
                            v
                         Internet

   NFS volumes come from one NFS server pod whose data lives on an Azure disk (ZRS).
   Nodes: 3 system nodes + 3 workload nodes, one per availability zone.
```

Namespaces: `istio-system`, `istio-ingress`, `istio-egress`, `nfs-storage`, `postgres`,
`keycloak`, `apps`.

---

## Before you start

**Programs on your computer**

| Program | Needed for | Notes |
| --- | --- | --- |
| Azure CLI (`az`) | Azure resources | 2.60 or newer |
| `kubectl` | talking to Kubernetes | 1.35 fits all stages (one minor version of skew is fine); `az aks install-cli` installs it |
| `helm` | installing charts | Helm 3 and Helm 4 both work; the scripts adapt |
| `docker` | building the two app images | not needed with `USE_ACR_BUILD=true` |
| `openssl`, `curl` | certificate, passwords, tests | usually installed already |
| `bash` | the scripts | works with the old bash 3.2 on macOS |

`./scripts/install/00-check-prereqs.sh` checks all of this and changes nothing.

**In Azure**

- A subscription where you may create resource groups and role assignments (Owner, or
  Contributor plus User Access Administrator).
- **vCPU quota** in the region: 18 vCPUs to install, about 22 while a surge upgrade adds
  nodes, 30 for the blue/green node pool variant. Script `01` checks and warns.
- A region with three availability zones that offers Kubernetes 1.34 (default `eastus2`).
  Check with `az aks get-versions --location eastus2 --output table`. If 1.34 is no longer
  offered, raise the versions in `config/versions.env`.

**Cost and time**

Six virtual machines, a load balancer, a disk and a registry run while the example exists -
very roughly one US dollar per hour at list prices (check the Azure pricing calculator).
Install takes about 30 minutes, the full upgrade 1 to 2 hours. **Run the destroy script when
you are done.**

**Settings**

All settings have defaults in [`config/env.sh`](config/env.sh). Override any of them with an
environment variable, for example:

```bash
export LOCATION=westeurope
export PREFIX=mydemo            # becomes part of every resource name
export USE_ACR_BUILD=true       # build images in Azure instead of local Docker
```

---

## Quick start

```bash
# 1. Install everything with the OLD versions (about 30 minutes)
./scripts/install/install-all.sh

# 2. Look at it
./scripts/tools/show-urls.sh        # addresses and test logins
./scripts/tools/show-status.sh      # versions, pods, budgets, volumes

# 3. Upgrade everything to the NEWEST versions (1 to 2 hours)
./scripts/upgrade/upgrade-all.sh

# 4. Remove everything (stops the costs)
./scripts/destroy/destroy-all.sh
```

Each `-all` script only calls the numbered scripts next to it. To learn, run the numbered
scripts yourself, one at a time, and read them - that is what they are for.

Scripts ask before they do something that cannot be undone. `ASSUME_YES=true` skips the
questions.

---

## Folder layout

```
config/
  versions.env            old and new versions, upgrade paths
  env.sh                  names, sizes, region and other settings
scripts/
  lib/common.sh           logging, state, small helpers (used by every script)
  lib/deploy.sh           "how to deploy X at version Y" - one function per component
  install/00..24 + install-all.sh
  upgrade/00..60 + upgrade-all.sh
  rollback/rollback-*.sh
  destroy/01..08 + destroy-all.sh
  tools/                  login test, status, URLs, availability probe, istioctl download, image mirror
k8s/                      plain manifests applied with kubectl
  namespaces.yaml
  storage/                StorageClasses and the two shared volume claims
  postgres/               ServiceAccount and the stable Service "postgres"
  istio/                  mTLS, authorization, gateway, routes, sticky sessions, egress
helm/
  charts/postgres         small chart: one StatefulSet per PostgreSQL major version
  charts/keycloak         small chart: Deployment, realm import, cluster Service, budget
  charts/spring-app       one chart for both apps
  values/                 values files for our charts and for the Istio and NFS charts
apps/
  app1/                   Portal  (Spring Boot 4, Java 21, Dockerfile, static page)
  app2/                   Reports (same code base, other name and look)
terraform/                the same system with Terraform / OpenTofu (three layers)
README.md                         this file
TUTORIAL-gotchas-and-rollback.md  traps, background, rollback step by step
```

Two folders appear when you run scripts and are never committed:

- `logs/` - one log file per script run, the journal `steps.log`, availability CSV files.
- `.state/` - what the scripts remember (names, versions), generated passwords, the private
  CA, the kubeconfig of this cluster and local copies of database dumps. Readable only by you.

The scripts use **their own kubeconfig** (`.state/kubeconfig`), never `~/.kube/config`, so
they cannot touch another cluster by accident. To use `kubectl` yourself:
`export KUBECONFIG=$PWD/.state/kubeconfig`.

---

## Install: one script per action

| Script | What it does |
| --- | --- |
| `00-check-prereqs.sh` | checks the programs, shows the settings |
| `01-azure-login.sh` | signs in, selects the subscription, registers providers, checks quota |
| `02-create-resource-group.sh` | the group that holds everything |
| `03-create-acr.sh` | container registry for the app images |
| `04-create-public-ip.sh` | static, zone-redundant public IP; derives the `nip.io` host names |
| `05-create-aks-cluster.sh` | AKS with Kubernetes 1.34, Standard tier, 3 system nodes in 3 zones |
| `06-add-user-nodepool.sh` | 3 workload nodes in 3 zones, with surge settings |
| `07-grant-network-role.sh` | lets the cluster use the static IP |
| `08-get-credentials.sh` | kubeconfig into `.state/` |
| `09-create-namespaces.sh` | namespaces; three of them with sidecar injection |
| `10-install-nfs-storage.sh` | NFS server pod (or Azure Files) and the two shared volumes |
| `11-install-istio-base.sh` | Istio CRDs |
| `12-install-istiod.sh` | Istio control plane as revision `1-28-1`, two pods |
| `13-set-revision-tag.sh` | the tag `stable` that namespaces and gateways refer to |
| `14-create-tls-certificate.sh` | private CA and wildcard certificate |
| `15-install-ingress-gateway.sh` | ingress gateway behind the static IP |
| `16-install-egress-gateway.sh` | egress gateway |
| `17-apply-mesh-policies.sh` | strict mTLS, who may call whom, the allowed egress host |
| `18-create-secrets.sh` | generates passwords, creates Kubernetes secrets |
| `19-install-postgres.sh` | PostgreSQL 14 on NFS, stable Service `postgres` |
| `20-install-keycloak.sh` | Keycloak 24, two pods, realm `demo` with test users |
| `21-build-push-images.sh` | builds and pushes both app images |
| `22-deploy-apps.sh` | both apps, two pods each |
| `23-apply-routing.sh` | Gateway, VirtualServices, DestinationRules |
| `24-smoke-test.sh` | checks the public endpoints (also used after each upgrade stage) |

All scripts are safe to run again. If one fails, fix the cause and re-run it (or
`install-all.sh`).

---

## Upgrade: the safe order and why

`upgrade-all.sh` runs these stages. You can also run each numbered script by hand.

| # | Stage | Scripts | What users notice |
| --- | --- | --- | --- |
| 1 | Checks and backups | `00` preflight, `01` database dump, `02` cluster snapshot | nothing |
| 2 | **Istio**, one minor version per round | `10` precheck → `11` CRDs → `12` new control plane (canary) → `13` switch tag → `14` restart workloads → `15` gateways → `16` verify → `17` remove old (`18` = all rounds) | apps stay up; logins pause for some seconds each time the single database pod restarts |
| 3 | **Kubernetes**, one minor version per round | `20` control plane → `21` node pools (or `22`-`24` blue/green) (`25` = all rounds) | apps stay up; logins pause when the database or NFS pod moves to another node |
| 4 | **Keycloak** | `30` | logins are down for a few minutes; signed-in users keep working |
| 5 | **PostgreSQL** | `40` new server → `41` copy data → `42` switch (`43` retire old, by hand) | logins are down for a few minutes |
| 6 | **Apps** | `21` build, `50` rolling update | nothing, or one automatic re-login |
| 7 | Verify | `60`, availability report | - |

**Why this order?**

1. **Istio before Kubernetes.** Every Istio release supports only a window of Kubernetes
   versions. Istio 1.28 supports Kubernetes up to 1.34, so the cluster cannot go to 1.35
   until Istio is newer. The scripts know the table and refuse an unsupported combination.
2. **One minor version at a time**, for Kubernetes (AKS enforces it) and for Istio.
3. **Control plane before nodes.** Nodes may be older than the control plane, never newer.
4. **Keycloak before PostgreSQL.** Keycloak 26 still supports PostgreSQL 14, so each change
   can be checked - and rolled back - on its own. Change one thing at a time.
5. **Apps last**, on top of a platform that is already proven.

The Istio upgrade is a **canary upgrade**: the new control plane is installed *next to* the
old one, a tag is moved, and pods pick up the new sidecar when they restart. Until the old
control plane is removed (`17`), going back takes one command.

---

## High availability: what is built in

| Measure | Where | Why it matters during an upgrade |
| --- | --- | --- |
| Three availability zones for nodes and public IP | `05`, `06`, `04` | a zone outage or a node replacement never takes all copies |
| Standard tier control plane | `05` | uptime SLA for the Kubernetes API |
| Separate system and workload node pools | `05`, `06` | workload nodes can be replaced without touching cluster add-ons |
| Surge upgrades (`--max-surge 33%`), drain timeout, soak time | `05`, `06`, `21` | a new node is added before an old one is drained, with a pause to notice problems |
| At least two pods for istiod, both gateways, Keycloak and each app | values files | one pod can go away at any time |
| PodDisruptionBudget `minAvailable: 1` (with `unhealthyPodEvictionPolicy: AlwaysAllow`) | charts, values | a node drain may never evict the last healthy pod - and a broken pod cannot block the drain |
| Topology spread over zones and nodes | charts, values | the two pods do not sit on the same node |
| Rolling update with `maxUnavailable: 0`, `maxSurge: 1` | app and Keycloak charts | a new pod must be ready before an old one stops |
| Startup, readiness and liveness probes | charts | traffic only goes to pods that can answer |
| `preStop` sleep + graceful shutdown | charts, `application.yaml` | a stopping pod finishes its requests while the mesh stops sending new ones |
| Sidecar starts first, stops last (`holdApplicationUntilProxyStarts`, `EXIT_ON_ZERO_ACTIVE_CONNECTIONS`) | `helm/values/istiod.yaml` | no failed calls at pod start or stop |
| Retries and outlier detection | `k8s/istio/` | a request that hits a dying pod is retried on another one |
| Istio revisions + tag (canary upgrade) | `12`, `13`, upgrade `10`-`17` | old and new control plane side by side; instant way back |
| Static public IP owned by you | `04`, `15` | address and certificate survive upgrades and even a new cluster |
| Zone-redundant disk (`Premium_ZRS`) behind the NFS pod | `k8s/storage/` | the NFS pod can restart in another zone and re-attach its data |
| Backups before every risky step | upgrade `01`, `30`, `41` | the way back for data |
| No automatic upgrades (`--auto-upgrade-channel none`) | `05` | nothing changes behind your back during the exercise |
| Availability probe | `scripts/tools/availability-probe.sh` | you *measure* downtime instead of guessing |

---

## What is NOT highly available here

An honest list. These are deliberate shortcuts of an example, and the preflight check prints
them every time.

| Single point of failure | Effect | What to use in production |
| --- | --- | --- |
| **PostgreSQL is one pod** | when its node is drained, or its sidecar is restarted, Keycloak cannot reach the database for up to a minute: logins fail, signed-in users keep working | Azure Database for PostgreSQL Flexible Server (zone-redundant), or an operator such as CloudNativePG with replicas and automatic failover |
| **The NFS server is one pod** | when it moves, every NFS volume pauses until it is back (the disk has to be re-attached) | Azure Files with NFS (`STORAGE_BACKEND=azurefiles-nfs`) or Azure NetApp Files |
| **PostgreSQL data on NFS** | fine for a demo, not recommended for a busy database | a managed database or a block-storage disk per replica |
| **App sessions live in pod memory** | when "your" pod is replaced you are signed in again automatically, but unsaved input in a form would be lost | Spring Session with Redis, so any pod can serve any user |
| **Keycloak upgrade and database migration need a stop** | logins are down for a few minutes | plan a maintenance window; for the database, logical replication can shrink the pause |
| **Private CA, `nip.io` names** | browser warning; depends on a public DNS service | a real domain and certificate (for example cert-manager with Let's Encrypt) |

---

## Rollback at a glance

Details, background and a hands-on exercise are in the
[tutorial](TUTORIAL-gotchas-and-rollback.md).

| What | Script | How it works | Cost of going back |
| --- | --- | --- | --- |
| Apps | `rollback/rollback-apps.sh` | `helm rollback` to the recorded revision; rolling | none |
| Istio | `rollback/rollback-istio.sh` | tag back to the old control plane, restart workloads | none before step `17`; after it the old version is installed again first |
| Node pool (blue/green) | `rollback/rollback-nodepool-bluegreen.sh` | uncordon old pool, drain new pool | none before the old pool is deleted |
| Kubernetes control plane | - | **not possible** - AKS has no downgrade | test first; restore into a new cluster if you must |
| Keycloak | `rollback/rollback-keycloak.sh` | restore the dump taken right before the upgrade, then `helm rollback` | changes in Keycloak since the upgrade are lost |
| PostgreSQL | `rollback/rollback-postgres.sh` | point the Service back at the old server (kept running) | data written since the switch is lost |

The pattern behind all of them: **keep the old thing until the new thing is proven** (old
istiod, old node pool, old database server, old Helm revision, a dump).

---

## Logs: every step is written down

- **`logs/<time>-<script>.log`** - everything a script printed, including every command
  line it ran (`[CMD  ] ...`) with time stamps.
- **`logs/steps.log`** - the journal: one line per step of every script, with start, end,
  duration and every fact that was stored. Example:

  ```
  2026-10-04T10:12:01Z | 13-istio-switch-tag | START (log=.../20261004-101201-13-istio-switch-tag.log)
  2026-10-04T10:12:01Z | 13-istio-switch-tag | STEP 3: Move tag 'stable' from 1.28.1 to 1.29.8
  2026-10-04T10:12:09Z | 13-istio-switch-tag | STATE ISTIO_ACTIVE_VERSION=1.29.8
  2026-10-04T10:12:09Z | 13-istio-switch-tag | DONE in 8s
  ```

- **`logs/availability-<time>.csv`** - one line per probe request (time, service, HTTP
  status, seconds). `./scripts/tools/availability-probe.sh report` turns it into availability
  per service and the longest outage.
- Passwords are never written to a log. Commands that need a password read it from a file
  or from standard input instead of the command line.

---

## Test users and the login test

Realm `demo` is imported on Keycloak's first start.

| User | Roles | Notes |
| --- | --- | --- |
| `alice` | `user`, `admin` | may open the admin area of both apps |
| `bob` | `user` | gets "403" in the admin area |
| `carol` | `user` | |

All three share one generated password. `./scripts/tools/show-urls.sh` prints it (and the
Keycloak admin password) on your terminal only - not into the log.

`./scripts/tools/test-login.sh [user]` plays a complete browser login with `curl`:
login form → password → token exchange → API call → single sign-on into the second app →
a note written through app1 and read through app2 (shared NFS volume) → allowed and blocked
egress call → logout. It runs after the install and after the upgrade.

In the browser: open `https://app1.<ip>.nip.io`, accept the certificate warning (or import
`.state/tls/ca.crt` as a trusted root), sign in, then open the second app - no second
password.

---

## Shared volumes and the NFS pod

"Shared" means **ReadWriteMany**: many pods on different nodes mount the same folder at the
same time. A normal Azure disk cannot do that; NFS can.

| Volume | Namespace | Used by | Purpose |
| --- | --- | --- | --- |
| `data-postgres-v<major>-0` | `postgres` | one PostgreSQL pod each | the database files |
| `pg-backups` | `postgres` | old **and** new PostgreSQL pod | dumps; the hand-over point of the migration |
| `shared-notes` | `apps` | all four app pods | notes written in one app show up in the other |

Two backends, chosen with `STORAGE_BACKEND`:

| | `nfs-pod` (default) | `azurefiles-nfs` |
| --- | --- | --- |
| What | NFS server pod (chart `nfs-server-provisioner`) on one Azure disk | Azure Files Premium shares with the NFS protocol |
| Good | shows exactly how NFS in a pod works; cheap; no extra Azure service | no pod to look after; no single pod to fail; Azure keeps it available |
| Bad | **one pod = single point of failure**; volumes pause while it restarts | small claims are rounded up to the minimum share size (100 GiB for Premium), so it costs more; slower for many small files |
| Use for | learning, demos | production |

Good to know about the NFS pod (more in the tutorial):

- Its namespace is **outside the mesh**. Nodes mount NFS themselves (the kubelet does), and a
  node has no sidecar.
- Volumes are mounted `hard`: when the server is away, programs wait instead of getting
  errors. That is what you want for a database.
- StorageClasses use `Retain`: deleting a claim by accident does not delete the data. The
  destroy scripts switch volumes to `Delete` first so nothing is left behind.

---

## Istio: the way in and the way out

**In (ingress).** The gateway pods listen on 80 and 443. Port 80 only redirects to HTTPS.
On 443 TLS ends with the wildcard certificate, and three VirtualServices route by host name
to `app1`, `app2` and `keycloak`. DestinationRules add sticky sessions (a cookie) and
outlier detection.

**Between pods.** `PeerAuthentication` demands mutual TLS everywhere. AuthorizationPolicies
allow only: gateway → apps, gateway and apps → Keycloak, Keycloak → PostgreSQL.

**Out (egress).** `outboundTrafficPolicy: REGISTRY_ONLY` makes sidecars refuse hosts the mesh
does not know. One host (`api.ipify.org`) is registered and routed through the egress
gateway. The apps have two buttons that show the difference.

Be careful what you conclude from this: `REGISTRY_ONLY` is a guard rail, not a wall. A pod
without a sidecar is not stopped by it. For real enforcement add Kubernetes NetworkPolicies
(or Azure Firewall) that allow outbound traffic only from the egress gateway.

---

## The two apps

Both are the same small Spring Boot 4.1 application (Java 21) with different names and looks.

- **Login**: OpenID Connect "authorization code" flow with Spring Security. The browser goes
  to Keycloak's public address; the pod swaps the code for tokens over the internal address
  (inside the mesh). See the comments in `SecurityConfig.java` for why the two addresses are
  configured separately.
- **Page**: one static `index.html` with Tailwind CSS (loaded from a CDN - fine for a demo)
  and one `app.js`. The header shows the version and the **name of the pod that answered**,
  refreshed every 5 seconds - watch it change during an upgrade.
- **Version**: the version number is a build argument (`APP_VERSION`), so 1.0.0 and 2.0.0 are
  built from the same sources. In real life the code would differ; the upgrade mechanics are
  the same.
- **Build**: `docker build` locally, or `USE_ACR_BUILD=true` to build inside Azure.

---

## Terraform version

[`terraform/`](terraform/) builds the same system with Terraform or OpenTofu, in three
layers (Azure → platform → workloads). Upgrades are changes to a few variables, applied one
step at a time. It reuses the same Helm values and Kubernetes manifests as the scripts.
See [`terraform/README.md`](terraform/README.md).

Use a **separate copy** of this project for the Terraform example: both keep their facts in
`.state/`.

---

## Destroy

```bash
./scripts/destroy/destroy-all.sh              # cluster, resource group, local state
./scripts/destroy/destroy-all.sh --graceful   # first uninstall everything inside the cluster, step by step
```

The fast way is enough: deleting the cluster and the resource group removes every disk, IP
and image. The graceful way exists to show (and log) the orderly teardown - apps, Keycloak,
PostgreSQL, Istio, storage - with one script each (`01` to `05`).

Afterwards check the Azure portal once: the resource group `rg-<prefix>` and the node
resource group `MC_...` must be gone.

---

## What was tested and what was not

**Checked in a sandbox without Azure access**

- All shell scripts pass `shellcheck`; a checker confirms a comment above every command line.
- Every `az` command line the scripts produce was verified, flag by flag, against the help
  of Azure CLI 2.90.
- Install, full upgrade (surge and blue/green), every rollback and both destroy modes ran
  end to end against stub tools that record the calls and answer plausibly. The stubs
  behaved like Helm 4; the install was also run with the Helm 3 flag set.
- The three local Helm charts and the upstream Istio 1.28.1 / 1.31.1 and NFS charts were
  rendered with the real Helm template engine and the values files of this project; the
  results and all `k8s/` manifests pass schema validation for Kubernetes 1.34 and 1.36
  including the Istio resource types.
- The Java sources were type-checked against the real source code of Spring Boot 4.1.1,
  Spring Security 7.1.1 and Spring Framework 7.0.9. The page logic was tested with a
  simulated browser and a fake API.
- The Terraform layers pass `tofu validate` with the real providers (azurerm 5.8,
  kubernetes 3.3, helm 3.3).

**Not done**

- Nothing was run against a real Azure subscription. Timing, quotas, Azure-side errors and
  the behaviour of real pods are untested.
- The apps were never built with Maven or run; a compile or start-up problem is possible.
- Whether the charts of the two Istio versions *in between* (1.29.8, 1.30.5) accept the same
  values was not rendered (the oldest and the newest were).
- One design choice rests on reading chart sources, not on a reproduced failure: Istio
  charts are installed with client-side apply under Helm 4 (see the tutorial, "Helm").

If something fails on your first run, the log of the failing script shows the exact command;
most scripts can simply be run again after the cause is fixed.

---

## Where to read next

- [`TUTORIAL-gotchas-and-rollback.md`](TUTORIAL-gotchas-and-rollback.md) - a hands-on
  exercise (upgrade something, break nothing, roll it back), then every trap we know, with
  the reason and the fix.
- [`terraform/README.md`](terraform/README.md) - the Terraform way.
- The scripts themselves. Start with `scripts/lib/common.sh`, then read an install script
  and an upgrade script top to bottom.
