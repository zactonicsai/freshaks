# Tutorial: upgrade traps ("gotchas") and how to make rollback easy

This tutorial belongs to the example in this folder (see [`README.md`](README.md)): a
Kubernetes cluster that runs in Docker containers on your own machine. It has two halves:

- **Part 1** is hands-on. You upgrade things, watch what users would see, and roll them
  back - step by step, with the exact commands.
- **Parts 2 to 7** explain the ideas, list every trap we know, compare your options, and end
  with a checklist and a small dictionary.

You do not need to be an expert. If a word is new, look at the
[dictionary](#part-7---small-dictionary) at the end.

> Honest note: the example was tested against a real Kubernetes API server with simulated
> nodes, but not on a real Docker engine (see "What was tested" in the README). Times below
> are estimates.

---

## Contents

- [Part 1 - Do it once: upgrade, watch, roll back](#part-1---do-it-once-upgrade-watch-roll-back)
- [Part 2 - The ideas behind it](#part-2---the-ideas-behind-it)
- [Part 3 - The rollback playbook](#part-3---the-rollback-playbook)
- [Part 4 - Gotchas](#part-4---gotchas)
- [Part 5 - Your options, with pros and cons](#part-5---your-options-with-pros-and-cons)
- [Part 6 - Best-practice checklist](#part-6---best-practice-checklist)
- [Part 7 - Small dictionary](#part-7---small-dictionary)

---

## Part 1 - Do it once: upgrade, watch, roll back

### What you need

- Docker with 8 GB of memory (see the README).
- The example installed with the old versions:

  ```bash
  ./scripts/install/install-all.sh
  ```

- Two terminal windows in the project folder, and a browser.

### Step 1 - Start watching

Terminal 1: start the availability probe. Once per second it asks each service for a page,
through the load balancer, and writes down whether it got an answer.

```bash
./scripts/tools/availability-probe.sh start
```

Terminal 2: watch the pods and the nodes they run on. (`in-tools.sh` runs `kubectl` in the
tools container, so you do not need it on your machine.)

```bash
./scripts/tools/in-tools.sh kubectl get pods --all-namespaces --output wide --watch
```

Browser: open <https://app1.localhost:8443>, accept the certificate warning and sign in as
`alice` (`./scripts/tools/show-status.sh` prints the password). Look at the top of the page:
it shows the **version** and the **pod that answered**, and refreshes every 5 seconds. This
is your window into the cluster.

### Step 2 - Exercise A: upgrade the apps, then roll them back

Build version 2.0.0 and roll it out (terminal 1):

```bash
./scripts/install/08-build-image.sh 2.0.0
./scripts/upgrade/50-apps-upgrade.sh 2.0.0
```

What to watch:

- Terminal 2: a **new** pod appears and becomes `2/2 Running` *before* an old pod is
  stopped. That is the rule `maxUnavailable: 0` at work.
- Browser: the version at the top changes to 2.0.0 and the pod name changes. The page keeps
  working. If "your" pod was replaced, the page says so and one click signs you in again
  without a password.

The script wrote down the way back before it changed anything. Look:

```bash
grep ROLLBACK .state/state.env
```

Now go back:

```bash
./scripts/rollback/rollback-apps.sh
```

The same thing happens in reverse. **Nobody was offline at any moment.** This is the easiest
kind of rollback, because the apps keep no data of their own.

### Step 3 - Exercise B: one Istio upgrade, with a rollback in the middle

Istio goes from 1.28.1 to 1.29.8.

```bash
./scripts/upgrade/01-preflight-and-backup.sh   # is the cluster healthy? save a database dump
./scripts/upgrade/10-istio-install-canary.sh   # NEW control plane next to the OLD one
```

Stop here and look. Two control planes are running, and nothing uses the new one yet:

```bash
./scripts/tools/in-tools.sh kubectl get deployments --namespace istio-system --label-columns istio.io/rev
```

Now switch:

```bash
./scripts/upgrade/11-istio-switch.sh
```

Read its output slowly. It moves the tag `stable` to the new control plane - and that alone
changes **no running pod**. Then it restarts the workloads one after the other; each new pod
gets the new sidecar. At the end it lists the proxy version of every pod.

Imagine something looks wrong now. Because the old control plane is still installed, the way
back is one command:

```bash
./scripts/rollback/rollback-istio.sh
```

It points the tag back, restarts the workloads and gateways, and checks that every proxy
runs 1.28.1 again. The new control plane stays installed but unused, so you can try again:

```bash
./scripts/upgrade/11-istio-switch.sh 1.29.8
./scripts/upgrade/12-istio-remove-old.sh       # only now the easy way back is gone
```

### Step 4 - Exercise C: upgrade Kubernetes itself

First the control plane, from 1.34 to 1.35:

```bash
./scripts/upgrade/20-k8s-upgrade-control-plane.sh
```

Watch terminal 2 while it runs: the `--watch` command loses its connection for about a
minute, because the Kubernetes API is away. Now look at the browser: **the app keeps
working.** Running pods do not need the control plane to serve requests. Start the watch
again when the script is done.

```bash
./scripts/tools/in-tools.sh kubectl get nodes
```

The server shows 1.35, the three workers still 1.34. That is allowed: nodes may be one minor
version behind the control plane.

Now one worker node:

```bash
./scripts/upgrade/21-k8s-upgrade-node.sh agent-1
```

This is the heart of every Kubernetes upgrade. Follow the steps in the output:

1. **cordon** - the node gets no new pods;
2. **drain** - its pods are asked to leave. Watch terminal 2: for every pod that goes, a
   replacement starts on another node. The drain *waits* when taking a pod away would leave
   a service with no healthy pod (that is the PodDisruptionBudget);
3. the node is taken out of the load balancer;
4. its container is replaced with the newer image;
5. the node comes back `Ready` with version 1.35;
6. **uncordon** - it may receive pods again.

Do the same for `agent-2` and `agent-3`. You have now upgraded a Kubernetes cluster.

### Step 5 - Read the numbers

```bash
./scripts/tools/availability-probe.sh stop
./scripts/tools/availability-probe.sh report
tail -n 40 logs/steps.log
```

The report shows, per service, how many requests failed and the longest gap. Expect `app1`
and `app2` at or near 100 %. For `keycloak` you may see a few failed requests: PostgreSQL is
a single pod, and while it restarted or moved, Keycloak could not reach its database. That
is the honest cost of a single pod - and exactly the kind of thing you want to *see* on a
test system before your users see it.

### Step 6 - Finish

`./scripts/upgrade/upgrade-all.sh` does everything that is left and skips what is already
done. When you have finished playing: `./scripts/destroy/destroy-all.sh`.

### What you just learned

1. **Old and new side by side** beats "replace and hope".
2. **A switch is not a rollout.** Moving a tag (or changing an image) changes nothing until
   pods restart.
3. **Pods survive a node upgrade by moving** - if there are at least two of them and a
   budget protects them.
4. **Write down the way back before you start** (the scripts store it in `.state/`).
5. **Measure.** The probe turns "I think it was fine" into numbers.
6. **Things without data are easy to roll back. Things with data are not** - Part 3 shows
   how the example deals with that.

---

## Part 2 - The ideas behind it

### An "upgrade" is really four different jobs

| Job | What changes | In this example |
| --- | --- | --- |
| Control plane | the Kubernetes API server and its helpers | script `20`: replace the `server` container |
| Nodes | the machines that run your pods | script `21`: one worker at a time; **your pods must move** |
| Platform add-ons | Istio, storage, ... | scripts `10`-`12`, with Helm |
| Your software and its data | apps, Keycloak, PostgreSQL | scripts `30`, `40`, `50` |

They have different risks. The control plane upgrade does not touch running pods. The node
upgrade restarts *every* pod. Add-ons and databases have their own rules.

### How pods survive a node being upgraded

1. **Cordon**: the node is marked "no new pods here".
2. **Drain**: the pods on the node are asked to leave ("evicted"), one after another.
3. Their controllers (Deployment, StatefulSet) start replacements on other nodes.
4. The empty node is upgraded and comes back.

Two things keep your service alive during step 2:

- **More than one pod.** With two pods on two nodes, one can leave while the other answers.
- **A PodDisruptionBudget (PDB)**: a rule like "at least 1 pod of this app must stay
  available". The drain waits until the replacement pod is ready before it evicts the next
  one.

And the pods themselves must behave: a **readiness probe** tells Kubernetes when a new pod
can take traffic, and a **graceful shutdown** lets a leaving pod finish its work.

In a cloud, step 4 usually means "throw the old machine away and add a fresh one". Here it
means "replace the node's container with a newer image". The idea is the same.

### Rolling, canary, blue/green

- **Rolling**: replace pods (or nodes) a few at a time. Simple. Old and new run together for
  a short while, so they must get along.
- **Canary**: install the new version next to the old one and send only *some* things to it
  first. Istio's "revisions" work like this: two control planes, and you choose which one a
  pod uses.
- **Blue/green**: build a complete second set (green) next to the running one (blue), move
  everything over, keep blue until you are sure. The PostgreSQL upgrade here works like
  this. Costs double for a while; going back is trivial.

### Rollback, roll forward, and one-way doors

- **Rollback**: go back to the old version.
- **Roll forward**: fix the problem with an even newer version. Sometimes this is the only
  way.
- **One-way door**: a change you cannot simply undo. In this example there are four:
  1. The control plane: a newer Kubernetes rewrites what is stored in its database.
  2. A worker node that has been upgraded.
  3. Keycloak rewriting its database tables on the first start of a new version.
  4. Data written to the new PostgreSQL server after the switch (the old server never saw
     it).

  For a one-way door, the only "undo" is something you saved **before** you went through:
  a backup, or the old thing kept running.

### Compatibility windows

Software parts only work together within certain versions. Istio 1.28 officially supports
Kubernetes 1.30 to 1.34; Istio 1.31 supports 1.32 to 1.36. So you cannot simply jump
Kubernetes to 1.36 first. You "walk" both forward so that every step stays inside a window.
The scripts carry this table (`scripts/lib/deploy.sh`) and stop you when a step would leave
it. Always check the current tables yourself: they change with every release.

---

## Part 3 - The rollback playbook

The rule for all of them: **make the way back before you go forward, and keep it open until
the new version is proven.**

| Component | What the upgrade script saves first | How to go back | The way back closes when ... | You lose |
| --- | --- | --- | --- | --- |
| Apps | Helm revision numbers and the old version | `scripts/rollback/rollback-apps.sh` | Helm has pruned the revision (it keeps 10) - then the script deploys the old version again instead | nothing |
| Istio | the old control plane stays installed | `scripts/rollback/rollback-istio.sh` | you run `12-istio-remove-old.sh`; afterwards the script installs the old version again first (slower, and only if that version still supports your Kubernetes) | nothing |
| Control plane | a copy of its database and certificates, taken while it was stopped | `scripts/rollback/rollback-control-plane.sh` | the first worker node is upgraded (nodes may never be newer than the control plane) | every change made in the cluster since the backup |
| Worker nodes | - | no way back: fix the problem and go forward | - | - |
| Keycloak | Helm revision, old version, and a database dump taken while Keycloak was stopped | `scripts/rollback/rollback-keycloak.sh` (restore dump, then `helm rollback`) | the dump is deleted | every change in Keycloak since the upgrade (new users, password changes, sessions) |
| PostgreSQL | the old server keeps running with its data, untouched | `scripts/rollback/rollback-postgres.sh` | you run `41-postgres-retire-old.sh --delete` | everything written since the switch |

### Why Keycloak and PostgreSQL are different

Rolling back an app is like putting an old book back on the shelf. Rolling back a database
is like un-writing a diary: the pages written since then are gone.

That is why the scripts:

- **stop Keycloak before the dump**, so the dump is exactly the state the old version
  understands;
- **never change the old PostgreSQL server** - the new one is filled from a copy;
- **keep the old server running after the switch** (`upgrade-all.sh` does not retire it);
- tell you plainly what a rollback will cost, and ask before doing it.

And it is why you should decide quickly. The longer the new version runs, the more data a
rollback throws away. Check hard right after the switch; after a day, rolling forward is
usually the better choice.

### The control plane: possible here, impossible on a managed service

Here you own the control plane's database, so script `20` can copy it before the upgrade and
`rollback-control-plane.sh` can put it back. That is a last resort: it forgets everything
that happened in the cluster after the copy, and it only works while the worker nodes are
still on the old version.

On a managed service (AKS, EKS, GKE) you do not own that database, and there is **no**
downgrade at all. Protect yourself differently:

- Upgrade a test cluster first, with the same versions and the same manifests.
- Upgrade the control plane alone, then wait and watch before you touch the nodes.
- Keep everything needed to rebuild in code (this project is exactly that), plus data
  backups outside the cluster.

---

## Part 4 - Gotchas

Each entry: **what goes wrong**, *why*, and what to do. Where the example already handles
it, the place is named.

### Planning and order

1. **Upgrading Kubernetes before Istio breaks the mesh.** *Istio 1.28 does not support
   Kubernetes 1.35.* Upgrade Istio first, hop by hop. Scripts `10` and `20` check the window.
2. **The newest version is not always the right target.** *Kubernetes 1.37 exists, but the
   newest Istio (1.31) does not support it yet.* The path in `config/versions.env` stops at
   1.36 for that reason.
3. **Skipping a minor version is refused.** *Kubernetes supports upgrades only to the next
   minor version, and this example moves Istio one minor version at a time too.*
4. **Starting the next hop before the last one is finished.** *Nodes that fall too far
   behind the control plane are not supported.* Script `20` refuses while any worker is
   still on the old minor version.
5. **Brand-new ".0" releases.** *The first patch releases often fix upgrade bugs.* Prefer a
   version that has had a patch or two, unless you need a fix urgently.
6. **Old versions run out of support.** *Kubernetes and Istio each support only the last few
   minor versions.* Waiting too long forces several hops in a hurry.
7. **Changing several things at once.** *When something breaks you will not know which
   change did it.* One change, one check - that is why there are many small scripts.

### Kubernetes nodes and drains

8. **A PodDisruptionBudget that can never be satisfied blocks the drain.**
   *`minAvailable: 1` on an app with a single pod means "this pod may never be evicted".*
   The drain waits until its timeout and fails. Use two pods, or no budget for single pods.
   Scripts `01` and `21` list every budget that currently allows zero disruptions.
9. **A crashing pod behind a budget blocks the drain too.** *By default an unhealthy pod
   still counts against the budget.* Set `unhealthyPodEvictionPolicy: AlwaysAllow` (done in
   the charts and values files).
10. **Single pods mean a pause when their node goes.** PostgreSQL and the NFS server here.
    Know which ones you have.
11. **Pods that belong to no controller disappear for good.** *A drain deletes them and
    nobody recreates them.* Always use Deployments, StatefulSets or Jobs.
12. **One DNS pod.** *Every pod asks the cluster DNS for names. K3s starts a single CoreDNS
    pod; while it moves, name lookups fail everywhere.* Script `02` runs two.
13. **After a rolling node upgrade the pods are unevenly spread.** *Pods move away from a
    node that is drained, but nothing moves them back.* The last node ends up nearly empty.
    A `kubectl rollout restart` of a Deployment spreads its pods again.
14. **Kubernetes 1.35 no longer starts on "cgroup v1".** *The old way Linux limits
    containers is switched off by default from 1.35.* A machine that still uses it runs 1.34
    fine and then breaks during the upgrade. Script `01` checks before anything is installed.
15. **If a drain fails half-way, the node stays cordoned.** Fix the cause and run script
    `21` for the same node again; or `kubectl uncordon <node>` to give up.

### Kubernetes in Docker (this setup)

16. **A replaced node must keep its identity.** *A K3s node proves who it is with a password
    file. A new container without that file is rejected under the old name.* Each node keeps
    the file in a Docker volume (`docker-compose.yml`).
17. **Node addresses must not change.** *When a container is replaced it normally gets any
    free address.* The compose file gives every node a fixed one.
18. **Every node downloads its own images.** *Nodes do not share the images on your
    machine.* That is slow and can hit Docker Hub's limit for anonymous users (100 pulls
    per 6 hours). The `hub-cache` container fetches each image once for all nodes.
19. **"Too many open files" on Linux.** *All nodes share your machine's limit for file
    watchers, and the usual default is too low for four nodes.* Script `02` raises it (the
    change lasts until the next reboot).
20. **Pods cannot resolve outside names in some networks.** *K3s in Docker lets pods ask the
    public DNS server 8.8.8.8 for names outside the cluster.* If your network blocks that,
    the egress test fails. Cluster-internal names are not affected.
21. **Running `docker compose` by hand to change versions.** *The scripts keep the versions
    in `.env` and in `.state/`; a manual change gets them out of step.* `ps`, `stop`,
    `start` and `logs` are fine.
22. **The same image tag, built again.** *A node that already has `demo-app:1.0.0` does not
    download it a second time.* Give every build a new tag.
23. **A sleeping laptop.** *After wake-up the nodes need a moment to report in again.* Wait
    until `kubectl get nodes` shows `Ready` before you continue an upgrade.

### Istio

24. **Moving the tag changes no running pod.** *Sidecars are added when a pod is created.*
    Script `11` restarts the workloads and checks the versions.
25. **Gateways are forgotten.** *They are pods with a proxy too.* Script `11` upgrades their
    chart and restarts them if needed.
26. **Two different injection labels on one namespace.** *`istio-injection=enabled` and
    `istio.io/rev=...` fight each other.* Use only `istio.io/rev` with a tag (see
    `k8s/namespaces.yaml`).
27. **Removing the old control plane too early.** *The webhook that checks Istio objects
    must already point at the new one* (`defaultRevision`), otherwise every `kubectl apply`
    of an Istio object fails. Script `11` moves it before `12` may remove anything.
28. **Downgrading CRDs.** *It can delete fields from existing objects.* On rollback the
    example keeps the newer CRDs; newer definitions work with the older control plane.
29. **`REGISTRY_ONLY` is not a firewall.** *A pod without a sidecar ignores it.* Add
    NetworkPolicies if blocking outbound traffic really matters.
30. **Putting the NFS server into the mesh.** *Nodes mount NFS, and nodes have no sidecar* -
    with strict mutual TLS the mount would fail. The `nfs-storage` namespace has no injection
    label.
31. **Keycloak's cluster traffic through the sidecar.** *Keycloak pods talk to each other on
    ports 7800 and 57800 with their own protocol.* The chart excludes these ports from the
    sidecar.
32. **An unusual public port.** *The browser asks for `app1.localhost:8443`, but the gateway
    pod listens on 443.* Istio's gateways ignore the port when they pick a route, so routing
    works. The application behind the gateway still has to learn the real port - see 67.

### Helm

33. **Helm 4 renamed and changed things.** `--atomic` is now `--rollback-on-failure`, and
    Helm 4 applies manifests "server-side" by default.
34. **Server-side apply and Istio's webhooks.** *istiod edits its own webhook objects after
    the install.* A later `helm upgrade` of an Istio chart can then fail with a "conflict".
    The example installs Istio charts with `--server-side=false`. (This comes from reading
    the charts, not from a reproduced failure.)
35. **`--set image.tag=18.10` pulls the wrong image.** *Helm reads it as the number 18.1.*
    Use `--set-string` for tags (see `deploy_postgres`).
36. **`--reuse-values` hides new defaults.** Pass the complete values on every upgrade, as
    the deploy functions do.
37. **Helm remembers only the last 10 revisions.** A rollback target can be gone. The
    rollback scripts then deploy the old version again.
38. **Changing Helm-managed objects with `kubectl scale` or `kubectl edit`.** *Helm does not
    know, and the next upgrade quietly reverts it - or conflicts.* The example scales
    Keycloak through Helm (`--set replicaCount=0`).
39. **`helm rollback` restores definitions, not data.** It will not un-migrate a database.
40. **`helm uninstall` does not delete the volumes of a StatefulSet.** Good (your data
    survives), but they stay until you delete the claims.

### Keycloak

41. **Rolling update across versions.** *Old and new Keycloak pods cannot share one cluster,
    and the new one changes the database.* Stop all old pods, back up, start the new version
    (script `30`, update strategy `Recreate`). Recent Keycloak versions can roll between
    *patch* releases of the same minor version - check the release notes.
42. **The database migration is a one-way door.** The dump taken in script `30` is the only
    way back.
43. **Old option names stop working.** Between 24 and 26: `KC_PROXY=edge` became
    `KC_PROXY_HEADERS=xforwarded`; `KC_HOSTNAME_URL` became `KC_HOSTNAME` (a full URL);
    `KEYCLOAK_ADMIN` became `KC_BOOTSTRAP_ADMIN_USERNAME`; health checks moved to port 9000.
    That is why there are two values files in `helm/values/`.
44. **Health probes on the wrong port.** *New pods never become ready and the upgrade rolls
    back.* The probe port is part of the values file per version.
45. **`--import-realm` only works once.** *An existing realm is not overwritten.* Later
    changes to `demo-realm.json` do nothing; change the realm through Keycloak.
46. **"Issuer does not match."** *Pods reach Keycloak by an internal address, browsers by the
    public one, and the token names the public one.* The app lists the endpoints one by one
    (see `SecurityConfig.java`); Keycloak has a fixed public address.
47. **The public port is part of that address.** *Keycloak stores `https://app1.localhost:8443`
    as the allowed return address when it imports the realm.* Changing `HTTPS_PORT` after the
    install breaks every login. Choose the port before you install.
48. **Logging out of one app does not log you out of the other.** *Each app keeps its own
    session.* The Keycloak session is ended, so the other app cannot start a *new* login
    without a password - but its existing session lives on until it expires.

### PostgreSQL

49. **A new major version cannot open the old data folder.** Use dump and restore (done
    here), `pg_upgrade`, or replication.
50. **Dumping with the old `pg_dump`.** *Always use the tools of the version you move to.*
    Script `40` runs `pg_dump` in the new pod against the old server.
51. **The PostgreSQL 18 image stores data in a different folder.** *A chart written for 14
    would start 18 with an empty database in the wrong place.* The chart sets `PGDATA`
    explicitly, the same for every version.
52. **Restore fails on owners and permissions.** *Since version 15 the `public` schema has
    different default rights.* Restore with `--no-owner --no-acl` as the application role.
53. **Changing the Service while clients are connected.** *Open connections stay with the
    old server.* Script `40` stops Keycloak before it switches.
54. **Slow queries right after a restore.** *The new database has no statistics.* Run
    `ANALYZE` (done in script `40`).
55. **The password in the secret changed, the database did not notice.** *The image reads
    passwords only when it creates the data folder.* Change passwords with SQL afterwards.
56. **Forgetting the old server.** It still runs after the switch. Park it
    (`41-postgres-retire-old.sh`) once you are sure, delete it (`--delete`) later.

### NFS and shared storage

57. **One NFS pod is one point of failure.** While it moves, every NFS volume stands still.
58. **A small node image cannot mount NFS the usual way.** *The K3s node image has no NFS
    helper programs. Asked without a version, the mount falls back to old NFS 3 and fails.*
    The StorageClass says `vers=4.1`, which needs no helpers. Script `03` tests a real mount.
59. **Files seem to belong to "nobody".** *NFS 4 sends file owners as names, not numbers; a
    client that cannot translate the name shows "nobody". PostgreSQL then refuses to start:
    "data directory has wrong ownership".* The server is configured to send numbers
    (`docker/nfs/vfs.conf`), and script `03` checks the owner of a test file.
60. **"Soft" mounts corrupt data.** *They return errors to programs when the server is slow.*
    The StorageClass mounts `hard`: programs wait instead.
61. **Clients hang long after the NFS pod is back.** *NFS servers have a "grace period"
    after a restart (90 seconds by default).* The values file shortens it to 10.
62. **"Stale file handle" after the NFS pod moved to another node.** *File handles were tied
    to the disk's device number.* `device-based-fsids: false` in the values file avoids it.
63. **A disk that only one node can reach pins its pod to that node.** *When that node is
    drained the pod cannot start anywhere else.* Here the NFS server's disk is a Docker
    volume mounted into every worker; in a cloud you would pick a disk type that can attach
    in every zone.
64. **PostgreSQL on NFS.** It works for a demo. For real workloads use block storage or a
    managed database.

### Apps, sessions and login

65. **Sessions in pod memory.** *When a pod is replaced its sessions are gone.* Single
    sign-on hides most of it, but a half-filled form is lost. Use Spring Session with Redis
    for real applications.
66. **Login fails at random with two pods.** *The pod that started the login must also
    receive the answer.* Sticky sessions (a cookie set by Istio, see `destinationrules.yaml`)
    or shared sessions solve it.
67. **"Invalid redirect URI" behind a proxy on an unusual port.** *The app builds its own
    address from headers the proxy sends. Without a port header it assumes 443 and tells
    Keycloak to send the browser to the wrong place.* The routes set `x-forwarded-port`
    (`k8s/istio/virtualservices.yaml`), and the app trusts the proxy headers
    (`server.forward-headers-strategy: native`).
68. **Requests fail for a second when a pod stops.** *The pod exits before the mesh has
    stopped sending to it.* A `preStop` sleep plus graceful shutdown closes the gap.
69. **Forms and JavaScript calls rejected with 403.** *Spring Security protects against
    forged requests.* The page sends the token from the `XSRF-TOKEN` cookie back in the
    `X-XSRF-TOKEN` header.
70. **Tailwind from a CDN.** Fine for a demo. For production, build the CSS file.

### Names, certificates and browsers

71. **A wildcard certificate for `*.localhost` is not accepted.** *Browsers refuse wildcards
    directly under a top-level name.* The certificate lists the three host names one by one.
72. **A browser that does not know `*.localhost`.** Chrome, Edge and Firefox send such names
    to your own machine. For others add the names to your hosts file (the README shows the
    line).
73. **Certificate warnings, and an expired certificate after 90 days.** *The example uses a
    private CA.* Import `.state/tls/ca.crt`, and run script `05` again to renew.

### Scripts and tools

74. **Passwords in command lines end up in logs and process lists.** The scripts pass them
    through files or standard input.
75. **Comparing versions as text.** *"1.10" sorts before "1.9".* The scripts use `sort -V`.
76. **K3s versions contain a "+", image tags cannot.** The version is `v1.35.9+k3s1`, the
    image tag `v1.35.9-k3s1`. The scripts convert between the two.
77. **A `kubectl` much older or newer than the cluster.** Stay within one minor version.
    The tools image has 1.35, which fits 1.34 to 1.36.
78. **macOS ships a very old bash (3.2).** The scripts avoid features it does not have.

---

## Part 5 - Your options, with pros and cons

### Running Kubernetes on your own machine

| Option | Pros | Cons |
| --- | --- | --- |
| **K3s nodes as containers with Docker Compose** (this example) | only Docker needed; every node is visible in one file; a node upgrade is "replace the container" | you wire up load balancer and registry yourself; nodes are a small image without extras |
| **k3d** (a tool that manages K3s containers) | one command creates a cluster with load balancer and registry | one more tool; no command to upgrade a running cluster step by step |
| **kind** (Kubernetes in Docker) | the tool the Kubernetes project itself uses for testing; full node image | no supported way to upgrade a cluster in place |
| **minikube** | many drivers and add-ons; can raise the Kubernetes version of an existing cluster | the upgrade is one command for the whole cluster - you do not see or control the node-by-node steps |
| **Kubernetes in Docker Desktop** | already there | usually one node; limited choice of versions |

### Upgrading nodes

| Option | Pros | Cons | Choose when |
| --- | --- | --- | --- |
| **One by one, in place** (this example; "surge" in clouds adds a spare node first) | little extra capacity needed; simple | no real way back; you do not choose where pods go | most upgrades |
| **Blue/green: a second set of nodes** | old nodes untouched until you delete them; trivial way back | double capacity for a while; more steps | risky upgrades; sensitive single pods |
| **A whole new cluster** | even the control plane has a way back | a lot of work: data, addresses and certificates must move | big jumps; managed services where the control plane cannot go back |

### Upgrading Istio

| Option | Pros | Cons |
| --- | --- | --- |
| **Canary with revisions and a tag** (this example) | old and new side by side; fast way back | more moving parts; you must restart workloads and remember the gateways |
| **In-place** (replace the one control plane) | fewer steps | no way back except installing the old version again; everything switches at once |

### Upgrading PostgreSQL to a new major version

| Option | Pause for users | Way back | Effort |
| --- | --- | --- | --- |
| **Dump and restore into a new server** (this example) | the whole copy time (minutes here, hours for big data) | excellent: the old server is untouched | low |
| **`pg_upgrade` in place** | short | only with a copy or snapshot taken before | medium; trickier in containers (both versions' programs are needed) |
| **Logical replication to a new server** | seconds (only the switch) | good until you stop replication | high |
| **Managed database service** | handled by the provider, in a planned window | point-in-time restore | lowest day-to-day |

### Shared storage

| Option | Pros | Cons |
| --- | --- | --- |
| **NFS server pod** (this example) | simple; easy to understand; works anywhere | single pod; pauses when it moves; you run it yourself |
| **Managed file service** (for example Azure Files, Amazon EFS) | the provider keeps it available; nothing to run | costs more; not for heavy database use |
| **Storage built for clusters** (for example Longhorn, Rook/Ceph) | copies data across nodes; survives a node loss | a system of its own to learn and upgrade |

### Keeping users signed in

| Option | Pros | Cons |
| --- | --- | --- |
| **Sticky sessions, memory in the pod** (this example) | nothing extra to run | sessions are lost when a pod is replaced |
| **Shared session store** (Spring Session + Redis) | any pod serves any user; pod replacement is invisible | one more component to run and upgrade |
| **No server session** (tokens only) | nothing to share | different security trade-offs; more work in the browser |

### Ways to go back

| Option | Good for | Watch out |
| --- | --- | --- |
| **`helm rollback`** | definitions of stateless things | history is limited; does nothing for data |
| **Deploy the old version again** | same result, works without history | needs the old values and charts (keep them in version control) |
| **Keep the old thing running** (control plane of Istio, database server) | instant, safe | costs resources; you must clean up later |
| **Restore a backup** | data, and here even the control plane | you lose what happened since; test your restores |
| **Roll forward** | when a one-way door is behind you | needs a fix ready |

---

## Part 6 - Best-practice checklist

**Before**

- [ ] Read the release notes and upgrade notes of every version on your path.
- [ ] Check the compatibility windows (Kubernetes with Istio, application with database).
- [ ] Do the whole upgrade on a test system that matches production - this example is one.
- [ ] Every important service has two or more pods, a PodDisruptionBudget, probes and a
      graceful shutdown.
- [ ] No budget currently allows zero disruptions (`01-preflight-and-backup.sh`).
- [ ] Fresh backups of all data - and you have restored one at least once.
- [ ] Images you depend on are in your own registry or cache.
- [ ] You wrote down, per step, how to go back and when that way closes.
- [ ] People know when it happens (a maintenance window for the parts that pause).

**During**

- [ ] One change at a time. Check after each (`10-smoke-test.sh`, `test-login.sh`).
- [ ] Watch real user traffic or a probe, not only "pods are Running".
- [ ] Control plane first, then nodes, one node at a time.
- [ ] Istio before Kubernetes when the window demands it.
- [ ] Keep the old version until the new one is proven.
- [ ] If something is odd: stop, look at the log, decide. Do not push on.

**After**

- [ ] Verify versions everywhere (`60-verify.sh`).
- [ ] Read the availability report. Write down what paused and for how long.
- [ ] Clean up: old control plane, old database server, old images, old backups.
- [ ] Update your notes for next time - you will do this again in a few months.

---

## Part 7 - Small dictionary

| Word | Meaning |
| --- | --- |
| **Container / image** | A program packed with everything it needs / the package it is started from. |
| **Docker Compose** | A tool that starts several containers described in one file. |
| **Kubernetes** | Software that runs containers on a group of machines and keeps them running. |
| **K3s** | A small, complete Kubernetes that fits into one program. |
| **Control plane** | The "brain" of Kubernetes: the API server and its helpers. |
| **Node** | A machine that runs pods. Here: a container. |
| **Pod** | The smallest unit Kubernetes runs: one or more containers together. |
| **Deployment / StatefulSet** | Controllers that keep a wanted number of pods running (StatefulSet: with fixed names and their own volumes). |
| **Cordon / drain / uncordon** | Mark a node so no new pods land on it / ask all its pods to leave / allow pods again. |
| **PodDisruptionBudget (PDB)** | A rule that limits how many pods of an app may be taken away at once. |
| **Probe** | A check Kubernetes runs on a pod: started? ready for traffic? still alive? |
| **Helm / chart / release / revision** | A package manager for Kubernetes / a package / one installed copy of it / a numbered version of that copy. |
| **Istio / service mesh** | Software that puts a small proxy next to every pod to encrypt, route and control traffic. |
| **Sidecar** | That small proxy container inside each pod. |
| **Ingress / egress gateway** | The proxies at the door: for traffic coming in / going out. |
| **Revision (Istio) / revision tag** | One installed Istio control plane version / a movable name (here `stable`) that points at one. |
| **Canary** | Trying the new version next to the old one before switching everything. |
| **Blue/green** | Building a full second copy, switching over, keeping the old one for a while. |
| **Load balancer** | A program that spreads incoming connections over several machines and skips the unhealthy ones. |
| **Registry** | A store for container images. |
| **Mutual TLS (mTLS)** | Encryption where both sides prove who they are. |
| **OIDC / single sign-on** | A standard way to log in through a central service (here Keycloak) / one login for several apps. |
| **Realm / client** | In Keycloak: a space with its own users / an application that may ask for logins. |
| **NFS / ReadWriteMany** | A network file system / a volume many pods can mount at the same time. |
| **PV / PVC / StorageClass** | A piece of storage / a request for storage / a recipe for creating storage. |
| **Dump / restore** | Write a database into a file / load it back from the file. |
| **Rollback / roll forward** | Go back to the old version / fix by going to an even newer one. |
| **CRD** | Custom Resource Definition: teaches Kubernetes a new kind of object (for example Istio's `VirtualService`). |
| **cgroup** | The Linux feature that limits how much CPU and memory a container may use. |
