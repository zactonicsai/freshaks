# Upgrading Kubernetes without taking the service down - on your own machine, with only Docker

A small but complete Kubernetes cluster that runs **inside Docker containers**. You install
it with **old** versions of everything, then upgrade every part to the **newest** version
while a probe measures what users would notice. Every step is one small shell script, every
command in it has a comment, and every step is written to a log.

No cloud account, no Terraform, nothing to install except Docker: `kubectl` and `helm` run
in a container too.

| Part | Old version (installed) | Upgrade path | Newest version |
| --- | --- | --- | --- |
| Kubernetes (K3s) | 1.34.12 | 1.35.9 → 1.36.5 | 1.36.5 |
| Istio (ingress and egress) | 1.28.1 | 1.29.8 → 1.30.5 → 1.31.1 | 1.31.1 |
| Keycloak (single sign-on) | 24.0.5 | direct | 26.8.0 |
| PostgreSQL | 14.12 | new server next to the old one | 18.6 |
| Demo app (Spring Boot, deployed twice) | 1.0.0 | rolling update | 2.0.0 |

Versions are the ones current in October 2026. They live in one file,
[`config/versions.env`](config/versions.env).

> **Read this first: what was and was not tested.**
> The scripts were run end to end against a real Kubernetes API server with simulated
> nodes, but **never on a real Docker engine**, and the Java app was type-checked but not
> built. Treat your first run as a test run. Details:
> [What was tested](#what-was-tested-and-what-was-not).

---

## Contents

1. [What you get](#what-you-get)
2. [The picture](#the-picture)
3. [Before you start](#before-you-start)
4. [Quick start](#quick-start)
5. [Folder layout](#folder-layout)
6. [How a cluster fits into Docker](#how-a-cluster-fits-into-docker)
7. [Install: one script per action](#install-one-script-per-action)
8. [Upgrade: the safe order and why](#upgrade-the-safe-order-and-why)
9. [High availability: what is built in](#high-availability-what-is-built-in)
10. [What is NOT highly available here](#what-is-not-highly-available-here)
11. [Rollback at a glance](#rollback-at-a-glance)
12. [Logs: every step is written down](#logs-every-step-is-written-down)
13. [Test users and the login test](#test-users-and-the-login-test)
14. [Shared volumes and the NFS pod](#shared-volumes-and-the-nfs-pod)
15. [Istio: the way in and the way out](#istio-the-way-in-and-the-way-out)
16. [The demo app](#the-demo-app)
17. [Everyday commands](#everyday-commands)
18. [Destroy](#destroy)
19. [What was tested and what was not](#what-was-tested-and-what-was-not)
20. [Where to read next](#where-to-read-next)

---

## What you get

- **A real multi-node Kubernetes in Docker**: one control-plane node and three worker nodes
  (K3s, a small certified Kubernetes), each node is one container.
- **A real Kubernetes upgrade**: control plane first, then each worker node - cordon, drain,
  replace, uncordon - one at a time.
- **Shell scripts with `docker`, `kubectl` and `helm`** - 36 in total, one action each, a
  comment above every command. Install, upgrade, roll back, destroy, plus an `-all` script
  for install and for upgrade that runs the others in order.
- **Istio as the only way in and out**: ingress gateway, egress gateway, strict mutual TLS,
  upgraded with the canary method (old and new control plane side by side).
- **Keycloak** with a ready-made realm, two OIDC clients and three test users.
- **PostgreSQL** as Keycloak's database, with its data on shared NFS storage.
- **Two Spring Boot apps** (Portal and Reports) that log in through Keycloak with single
  sign-on, each with a static HTML page styled with Tailwind CSS and plain JavaScript.
- **Shared volumes on NFS**: an NFS server pod whose "disk" every node can reach.
- **A tutorial** about the traps and about easy rollback:
  [`TUTORIAL-gotchas-and-rollback.md`](TUTORIAL-gotchas-and-rollback.md).

---

## The picture

```
  your browser:  https://app1.localhost:8443
        |
+-------|------------------------------ Docker ----------------------------------+
|       v                                                                        |
|   edge (HAProxy load balancer) --- checks health, sends to a healthy node ---  |
|       |                  |                  |                                  |
|       v                  v                  v                                  |
|   agent-1 (zone-1)   agent-2 (zone-2)   agent-3 (zone-3)     server            |
|   worker node        worker node        worker node          control plane     |
|                                                              (Kubernetes API)  |
|                                                                                |
|   registry (your app image)   hub-cache (Docker Hub cache)   tools (kubectl,   |
|                                                               helm, curl)      |
+--------------------------------------------------------------------------------+

  Inside the Kubernetes cluster (pods on the three worker nodes):

        +----------------------------------------+
        |  Istio INGRESS gateway  (2 pods)       |  TLS ends here
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
        |  Istio EGRESS gateway  (2 pods)        |  only api.ipify.org is allowed
        +-------------------+--------------------+
                            v
                         Internet

   NFS volumes come from one NFS server pod. Its data lives in a Docker volume
   that is mounted into every worker node.
```

Namespaces: `istio-system`, `istio-ingress`, `istio-egress`, `nfs-storage`, `postgres`,
`keycloak`, `apps`.

---

## Before you start

**You need**

| | |
| --- | --- |
| Docker | Docker Desktop (macOS, Windows) or Docker Engine (Linux) with the `docker compose` plugin. Normal ("rootful") Docker with cgroup v2 - every current install has that. |
| A shell | `bash`. On Windows use WSL 2. The old bash 3.2 on macOS is fine. |
| Memory | Give Docker **8 GB** or more (Docker Desktop: Settings > Resources). |
| CPUs | 4 or more. |
| Disk | About 20 GB free (every node downloads its own images). |
| Internet | To download images and charts, and for the egress demo. |

`./scripts/install/01-check-docker.sh` checks this and changes nothing.

**Good to do**

- `docker login` with a free Docker Hub account. Anonymous users may pull 100 images per
  6 hours; an account raises the limit. The cluster itself pulls through a cache container,
  so each image is fetched from Docker Hub only once.
- Close other heavy programs. Thirty Java, proxy and database processes will start.

**Settings**

All settings have defaults in [`config/env.sh`](config/env.sh). Override them with
environment variables **before the first install**, for example:

```bash
export HTTPS_PORT=9443        # if port 8443 is taken on your machine
export SUBNET_PREFIX=172.31.7 # if Docker reports that the network overlaps another one
```

Ports, network and host name are remembered in `.state/` at the first install and used from
then on, whatever the environment says later. (The port becomes part of the addresses that
Keycloak stores.) To change them, destroy the example and install it again.

---

## Quick start

```bash
# 1. Install everything with the OLD versions (estimate: 10 to 20 minutes, mostly downloads)
./scripts/install/install-all.sh

# 2. Look at it
./scripts/tools/show-status.sh      # versions, pods, addresses, test logins

# 3. Upgrade everything to the NEWEST versions (estimate: about an hour)
./scripts/upgrade/upgrade-all.sh

# 4. Remove everything from your machine
./scripts/destroy/destroy-all.sh
```

Then open <https://app1.localhost:8443> and sign in as `alice`.

Each `-all` script only calls the numbered scripts next to it. **To learn, run the numbered
scripts yourself, one at a time, and read them** - that is what they are for. The
[tutorial](TUTORIAL-gotchas-and-rollback.md) walks you through it.

Scripts ask before they do something that cannot be undone. `ASSUME_YES=true` skips the
questions.

---

## Folder layout

```
docker-compose.yml        the cluster as containers: nodes, registries, load balancer, tools
config/
  versions.env            old and new versions, upgrade paths
  env.sh                  ports, sizes and other settings
docker/
  tools/Dockerfile        image with kubectl, helm, curl, openssl
  edge/haproxy.cfg        load balancer in front of the worker nodes
  k3s/registries.yaml     where the nodes find images
  nfs/vfs.conf            start configuration of the NFS server
scripts/
  lib/common.sh           logging, state, wrappers that run kubectl/helm in the tools container
  lib/deploy.sh           "how to deploy X at version Y" - one function per component
  install/01..10 + install-all.sh
  upgrade/01..60 + upgrade-all.sh
  rollback/rollback-*.sh
  destroy/destroy-all.sh
  tools/                  login test, status, availability probe, in-tools
k8s/                      plain manifests applied with kubectl
  namespaces.yaml
  storage/                the NFS server's disk and the two shared volume claims
  postgres/               ServiceAccount and the stable Service "postgres"
  istio/                  mTLS, authorization, gateway, routes, sticky sessions, egress
helm/
  charts/postgres         small chart: one StatefulSet per PostgreSQL major version
  charts/keycloak         small chart: Deployment, realm import, cluster Service, budget
  charts/spring-app       one chart, installed twice (app1 and app2)
  values/                 values files for our charts and for the Istio and NFS charts
apps/demo-app/            Spring Boot 4, Java 21, Dockerfile, two page designs
README.md                         this file
TUTORIAL-gotchas-and-rollback.md  hands-on exercise, traps, rollback step by step
```

Three things appear when you run scripts and are never committed:

- `logs/` - one log file per script run, the journal `steps.log`, availability CSV files.
- `.state/` - what the scripts remember (versions), generated passwords, the private CA,
  kubeconfig files and backups. Readable only by you.
- `.env` - versions, ports and the cluster token for `docker compose`, written by the scripts.

---

## How a cluster fits into Docker

`docker-compose.yml` describes eight containers:

| Container | What it is |
| --- | --- |
| `server` | Kubernetes control plane (K3s server). Its database and certificates live in a Docker volume. Application pods are kept off this node. |
| `agent-1`, `agent-2`, `agent-3` | Worker nodes (K3s agents). Each has a label that pretends it is in its own zone, and its own version setting - so nodes can be upgraded one at a time. |
| `edge` | HAProxy. Listens on port 8443 of your machine and passes connections to a healthy worker node. It does what a cloud load balancer does for a real cluster. |
| `registry` | Stores the image of the demo app. From your machine it is `localhost:5001`; the nodes call it `registry:5000`. One registry, two addresses. |
| `hub-cache` | A cache in front of Docker Hub. Nodes ask it for `docker.io` images; it fetches each one once. |
| `tools` | `kubectl`, `helm`, `curl` and `openssl`. The scripts run these with `docker exec`, so your machine needs none of them. The project folder is mounted at `/work`. |

**Upgrading a node = replacing its container with a newer image.** Everything the node must
remember (downloaded images, its identity) is in Docker volumes that survive the swap. This
is the same idea as replacing the K3s program on a real machine and restarting it.

The scripts write the node versions into `.env`. After the first install you can use normal
commands - `docker compose ps`, `docker compose stop`, `docker compose start` - but leave
version changes to the scripts.

---

## Install: one script per action

| Script | What it does |
| --- | --- |
| `01-check-docker.sh` | checks Docker, memory, CPUs; shows the settings |
| `02-start-cluster.sh` | builds the tools image, starts all containers, waits for four Ready nodes, writes the kubeconfig files, runs two DNS pods |
| `03-install-storage.sh` | namespaces, NFS server pod, the two shared volumes, and a test that a pod can really mount NFS |
| `04-install-istio.sh` | Istio CRDs, control plane as revision `1-28-1`, the tag `stable`, ingress and egress gateway |
| `05-apply-mesh-rules.sh` | private CA and certificate, strict mTLS, who may call whom, the allowed egress host, gateway and routes |
| `06-install-postgres.sh` | passwords, PostgreSQL 14 on NFS, the stable Service `postgres` |
| `07-install-keycloak.sh` | Keycloak 24, two pods, realm `demo` with clients and test users |
| `08-build-image.sh` | builds the demo app with Docker and pushes it to the local registry |
| `09-deploy-apps.sh` | Portal and Reports, two pods each |
| `10-smoke-test.sh` | checks the public endpoints (also used after each upgrade stage) |

All scripts are safe to run again. If one fails, fix the cause and re-run it (or
`install-all.sh`).

---

## Upgrade: the safe order and why

`upgrade-all.sh` runs these stages. You can also run each numbered script by hand.

| # | Stage | Scripts | What users notice |
| --- | --- | --- | --- |
| 1 | Checks and backups | `01-preflight-and-backup.sh` | nothing |
| 2 | **Istio**, one minor version per round | `10` new control plane next to the old one → `11` switch tag, restart workloads, upgrade gateways, verify → `12` remove the old one | apps stay up; logins pause for some seconds each time the single database pod restarts |
| 3 | **Kubernetes**, one minor version per round | `20` control plane (with backup) → `21 <node>` for each worker: cordon, drain, replace, uncordon | apps stay up; the Kubernetes API is away for about a minute during `20`; logins pause when the database or NFS pod moves |
| 4 | **Keycloak** | `30` | logins are down for a few minutes; signed-in users keep working |
| 5 | **PostgreSQL** | `40` new server, copy, switch (`41` retire the old one, by hand) | logins are down for a few minutes |
| 6 | **App** | `08` build, `50` rolling update | nothing, or one automatic re-login |
| 7 | Verify | `60`, availability report | - |

**Why this order?**

1. **Istio before Kubernetes.** Every Istio release supports only a window of Kubernetes
   versions. Istio 1.28 supports Kubernetes up to 1.34, so the cluster cannot go to 1.35
   until Istio is newer. The scripts know the table and refuse an unsupported combination.
2. **One minor version at a time**, for Kubernetes and for Istio.
3. **Control plane before nodes.** Nodes may be older than the control plane, never newer.
4. **Keycloak before PostgreSQL.** Keycloak 26 still supports PostgreSQL 14, so each change
   can be checked - and rolled back - on its own. Change one thing at a time.
5. **Apps last**, on top of a platform that is already proven.

Why does the path stop at Kubernetes 1.36 when 1.37 exists? Because Istio 1.31, the newest
Istio, does not support 1.37 yet. The newest version is not always the right target.

---

## High availability: what is built in

| Measure | Where | Why it matters during an upgrade |
| --- | --- | --- |
| Three worker nodes in three (pretend) zones | `docker-compose.yml` | one node can be taken away at any time |
| Load balancer with health checks; a node is taken out of rotation before it is stopped | `docker/edge/haproxy.cfg`, `21` | no connection is sent to a node that is going away |
| One node at a time: cordon, drain, replace, uncordon, wait | `21` | capacity drops by one node only, and only when the rest is healthy |
| At least two pods for istiod, both gateways, Keycloak, each app and DNS | values files, `02` | one pod can go away at any time |
| PodDisruptionBudget `minAvailable: 1` (with `unhealthyPodEvictionPolicy: AlwaysAllow`) | charts, values | a drain may never evict the last healthy pod - and a broken pod cannot block the drain |
| Topology spread over zones and nodes | charts, values | the two pods do not sit on the same node |
| Rolling update with `maxUnavailable: 0`, `maxSurge: 1` | app and Keycloak charts | a new pod must be ready before an old one stops |
| Startup, readiness and liveness probes | charts | traffic only goes to pods that can answer |
| `preStop` sleep + graceful shutdown | charts, `application.yaml` | a stopping pod finishes its requests while the mesh stops sending new ones |
| Sidecar starts first, stops last | `helm/values/istiod.yaml` | no failed calls at pod start or stop |
| Retries and outlier detection | `k8s/istio/` | a request that hits a dying pod is retried on another one |
| Istio revisions + tag (canary upgrade) | `04`, `10`-`12` | old and new control plane side by side; instant way back |
| The NFS server's disk is reachable from every node | `docker-compose.yml`, `k8s/storage/` | the NFS pod can restart on another node and find its data |
| Backups before every risky step | `01`, `20`, `30`, `40` | the way back for data and for the control plane |
| Pinned versions, no automatic upgrades | `config/versions.env` | nothing changes behind your back |
| Images come from a local registry and a cache | `docker-compose.yml` | replaced nodes can always download what they need |
| Availability probe | `scripts/tools/availability-probe.sh` | you *measure* downtime instead of guessing |

---

## What is NOT highly available here

An honest list. These are deliberate shortcuts of an example, and the preflight check prints
the first three every time.

| Single point of failure | Effect | What to use in production |
| --- | --- | --- |
| **One control-plane node** | while it is upgraded the Kubernetes API is away for about a minute: nothing can be deployed or rescheduled. Running pods keep serving. | three control-plane nodes, or a managed control plane (AKS, EKS, GKE) |
| **PostgreSQL is one pod** | when its node is drained, or its sidecar is restarted, Keycloak cannot reach the database for up to a minute: logins fail, signed-in users keep working | a managed database, or an operator such as CloudNativePG with replicas and automatic failover |
| **The NFS server is one pod** | when it moves, every NFS volume pauses until it is back | a managed file service, or storage built for clusters |
| **PostgreSQL data on NFS** | fine for a demo, not recommended for a busy database | a managed database or a block-storage disk per replica |
| **App sessions live in pod memory** | when "your" pod is replaced you are signed in again automatically, but unsaved input in a form would be lost | Spring Session with Redis, so any pod can serve any user |
| **Keycloak upgrade and database migration need a stop** | logins are down for a few minutes | plan a maintenance window |
| **Everything runs on one computer** | the "zones" are pretend; if your machine stops, everything stops | real machines in real zones |
| **Private CA, `localhost` names** | browser warning | a real domain and certificate |

---

## Rollback at a glance

Details, background and a hands-on exercise are in the
[tutorial](TUTORIAL-gotchas-and-rollback.md).

| What | Script | How it works | Cost of going back |
| --- | --- | --- | --- |
| Apps | `rollback/rollback-apps.sh` | `helm rollback` to the recorded revision; rolling | none |
| Istio | `rollback/rollback-istio.sh` | tag back to the old control plane, restart workloads | none before step `12`; after it the old version is installed again first |
| Kubernetes control plane | `rollback/rollback-control-plane.sh` | restore the backup taken by `20`, start the old image | only before the worker nodes are upgraded; cluster changes since the backup are lost |
| Worker nodes | - | no way back; fix forward | - |
| Keycloak | `rollback/rollback-keycloak.sh` | restore the dump taken right before the upgrade, then `helm rollback` | changes in Keycloak since the upgrade are lost |
| PostgreSQL | `rollback/rollback-postgres.sh` | point the Service back at the old server (kept running) | data written since the switch is lost |

The pattern behind all of them: **keep the old thing until the new thing is proven** (old
istiod, old database server, old Helm revision, a dump, a backup).

On a managed service (AKS, EKS, GKE) the control plane has **no** way back at all - you do
not own its database. That is why upgrades are tested first.

---

## Logs: every step is written down

- **`logs/<time>-<script>.log`** - everything a script printed, including every command
  line it ran (`[CMD  ] ...`) with time stamps.
- **`logs/steps.log`** - the journal: one line per step of every script, with start, end,
  duration and every fact that was stored. Example:

  ```
  2026-10-04T10:12:01Z | 21-k8s-upgrade-node | START (log=logs/20261004-101201-21-k8s-upgrade-node.log)
  2026-10-04T10:12:02Z | 21-k8s-upgrade-node | STEP 3: Drain agent-1: move its pods to the other nodes
  2026-10-04T10:12:40Z | 21-k8s-upgrade-node | STATE K8S_AGENT_1_VERSION=v1.35.9-k3s1
  2026-10-04T10:13:55Z | 21-k8s-upgrade-node | DONE in 114s
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

All three share one generated password. `./scripts/tools/show-status.sh` prints it (and the
Keycloak admin password) on your terminal only - not into the log.

`./scripts/tools/test-login.sh [user]` plays a complete browser login with `curl`:
login form → password → token exchange → API call → single sign-on into the second app →
a note written through app1 and read through app2 (shared NFS volume) → allowed and blocked
egress call → logout. It runs after the install and after the upgrade.

**In the browser:** open <https://app1.localhost:8443>, accept the certificate warning, sign
in, then open <https://app2.localhost:8443> - no second password.

- The certificate is signed by a private CA, so the browser warns once per host name
  (app1, app2, keycloak). To get rid of the warnings, import `.state/tls/ca.crt` as a
  trusted authority.
- Chrome, Edge and Firefox resolve every `*.localhost` name to your own machine. If your
  browser does not, add this line to your hosts file:
  `127.0.0.1 app1.localhost app2.localhost keycloak.localhost`

---

## Shared volumes and the NFS pod

"Shared" means **ReadWriteMany**: many pods on different nodes mount the same folder at the
same time. NFS can do that.

| Volume | Namespace | Used by | Purpose |
| --- | --- | --- | --- |
| `data-postgres-v<major>-0` | `postgres` | one PostgreSQL pod each | the database files |
| `pg-backups` | `postgres` | old **and** new PostgreSQL pod | dumps; the hand-over point of the migration |
| `shared-notes` | `apps` | all four app pods | notes written in one app show up in the other |

One pod (chart `nfs-server-provisioner`) runs the NFS server and creates a folder for every
claim that asks for StorageClass `nfs`. Its own data sits in a Docker volume that is mounted
into every worker node at the same path - the stand-in for a network disk that can be
attached anywhere. So when the NFS pod's node is drained, the pod restarts on another node
and finds everything.

Good to know (more in the tutorial):

- The NFS namespace is **outside the mesh**. Nodes mount NFS themselves, and a node has no
  sidecar.
- Volumes are mounted `hard`: when the server is away, programs wait instead of getting
  errors. That is what you want for a database.
- Volumes are mounted with NFS **version 4.1** on purpose: it needs no helper programs on
  the node, which the small K3s node image does not have.
- The server is told to report file owners as **numbers**
  ([`docker/nfs/vfs.conf`](docker/nfs/vfs.conf)). Without that, PostgreSQL may refuse to
  start because its files seem to belong to "nobody".
- `03-install-storage.sh` proves all of this with a test pod before anything depends on it.

---

## Istio: the way in and the way out

**In (ingress).** Your browser → `edge` container → port 30443 on a worker node → an
ingress gateway pod. The gateway ends TLS with the certificate, and three VirtualServices
route by host name to `app1`, `app2` and `keycloak`. DestinationRules add sticky sessions
(a cookie) and outlier detection.

**Between pods.** `PeerAuthentication` demands mutual TLS everywhere. AuthorizationPolicies
allow only: gateway → apps, gateway and apps → Keycloak, Keycloak → PostgreSQL.

**Out (egress).** `outboundTrafficPolicy: REGISTRY_ONLY` makes sidecars refuse hosts the mesh
does not know. One host (`api.ipify.org`) is registered and routed through the egress
gateway. The apps have two buttons that show the difference.

Be careful what you conclude from this: `REGISTRY_ONLY` is a guard rail, not a wall. A pod
without a sidecar is not stopped by it. For real enforcement add Kubernetes NetworkPolicies
that allow outbound traffic only from the egress gateway.

---

## The demo app

One small Spring Boot 4.1 application (Java 21), one image - **installed twice** with
different settings:

| | app1 | app2 |
| --- | --- | --- |
| Name | Portal | Reports |
| Page design | light | dark |
| OIDC client in Keycloak | `app1` | `app2` |
| Address | `https://app1.localhost:8443` | `https://app2.localhost:8443` |

- **Login**: OpenID Connect "authorization code" flow with Spring Security. The browser goes
  to Keycloak's public address; the pod swaps the code for tokens over the internal address
  (inside the mesh). See the comments in `SecurityConfig.java`.
- **Page**: static `index.html` with Tailwind CSS (loaded from a CDN - fine for a demo) and
  one `app.js`. The header shows the version and the **name of the pod that answered**,
  refreshed every 5 seconds - watch it change during an upgrade.
- **Version**: the version number is a build argument (`APP_VERSION`), so 1.0.0 and 2.0.0 are
  built from the same sources. In real life the code would differ; the upgrade mechanics are
  the same.

---

## Everyday commands

```bash
# kubectl and helm, without installing them
./scripts/tools/in-tools.sh kubectl get pods --all-namespaces --output wide
./scripts/tools/in-tools.sh kubectl get nodes
./scripts/tools/in-tools.sh helm list --all-namespaces

# if you do have kubectl on your machine
export KUBECONFIG=$PWD/.state/kubeconfig

# pause and resume the whole cluster (data is kept)
docker compose stop
docker compose start

# logs of a node or of the load balancer
docker logs k8s-ha-demo-agent-1
docker logs k8s-ha-demo-edge
```

---

## Destroy

```bash
./scripts/destroy/destroy-all.sh                # containers, network, volumes, local state
./scripts/destroy/destroy-all.sh --keep-images  # keep the registry and the Docker Hub cache
```

With `--keep-images` the next install needs far fewer downloads. The `logs/` folder is kept
either way. Images that Docker itself downloaded (K3s, HAProxy, ...) stay in Docker's image
cache; `docker image prune -a` removes them if you want the disk space back.

---

## What was tested and what was not

**Done, in a sandbox without a Docker engine**

- The real scripts ran end to end against a **real Kubernetes API server** (the K3s control
  plane, versions 1.34 and 1.36) with real controllers, scheduler and `kubectl`. Nodes and
  pods were simulated, and a stand-in answered the `docker` commands.
  - `install-all.sh`, the complete `upgrade-all.sh`, every rollback script and the destroy
    script passed.
  - The node upgrades used real `cordon` and `drain` against real PodDisruptionBudgets.
  - The scripts correctly refused: a skipped minor version, Kubernetes 1.36 while Istio was
    still 1.29, a control-plane rollback after nodes were upgraded, an unknown node.
  - Every chart and manifest was accepted by the real API, including Istio's real resource
    definitions (versions 1.28.1 and 1.31.1).
- Helm itself was **emulated**: charts were rendered with the real Helm template engine and
  applied with `kubectl`. Every Helm flag the scripts use was checked against the source
  code of Helm 4.2.4.
- `docker-compose.yml` passes the real `docker compose config`; `haproxy.cfg` passes a real
  HAProxy check; both Dockerfiles and all scripts pass their linters.
- The Java sources were type-checked against the source code of Spring Boot 4.1.1 and
  Spring Security 7.1.1. The page logic was tested with a simulated browser.

**Not done**

- **Nothing ran on a real Docker engine in my tests.** K3s in containers, the load balancer,
  the registries, real pods, real HTTP traffic: unproven. A first real run already found one
  wrong assumption about what the K3s image contains (it broke the "wait for the API" step
  and is fixed); expect that others may surface.
- **NFS mounts inside the K3s node containers** are the most likely first-run problem. They
  should work (the node's mount program was inspected), and `03-install-storage.sh` tests
  them early and stops with a clear message.
- The app was never built with Maven or run; a compile or start-up problem is possible.
- The real Helm 4 program never ran. One choice rests on reading chart sources, not on a
  reproduced failure: Istio charts are installed with `--server-side=false`.
- The Istio charts of the two versions in between (1.29.8, 1.30.5) were not rendered.
- No image was actually pulled, so image tags are unverified beyond their release tags.

If something fails on your first run, the log of the failing script shows the exact command;
most scripts can simply be run again after the cause is fixed. The tutorial lists the usual
causes.

---

## Where to read next

- [`TUTORIAL-gotchas-and-rollback.md`](TUTORIAL-gotchas-and-rollback.md) - a hands-on
  exercise (upgrade a node, upgrade Istio, roll things back), then every trap we know, with
  the reason and the fix.
- The scripts themselves. Start with `scripts/lib/common.sh`, then read
  `scripts/upgrade/21-k8s-upgrade-node.sh` top to bottom.
- `docker-compose.yml` - every line is explained.
