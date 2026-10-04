# Tutorial: upgrade traps ("gotchas") and how to make rollback easy

This tutorial belongs to the example in this folder (see [`README.md`](README.md)). It has
two halves:

- **Part 1** is hands-on. You upgrade something, watch what users would see, and roll it
  back - step by step, with the exact commands.
- **Parts 2 to 7** explain the ideas, list every trap we know, compare your options, and end
  with a checklist and a small dictionary.

You do not need to be an expert. If a word is new, look at the
[dictionary](#part-7---small-dictionary) at the end.

> Honest note: the example was checked carefully offline but not run on a real Azure
> subscription (see "What was tested" in the README). Times given below are estimates.

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

- The example installed with the old versions: `./scripts/install/install-all.sh`
  (about 30 minutes, see the README).
- Two terminal windows in the project folder.
- A browser.

### Step 1 - Start watching

In terminal 1, start the availability probe. Once per second it asks each service for a
page, through the real public address, and writes down whether it got an answer.

```bash
./scripts/tools/availability-probe.sh start
```

In terminal 2, point `kubectl` at this cluster and keep an eye on the pods:

```bash
export KUBECONFIG=$PWD/.state/kubeconfig
kubectl get pods --namespace apps --watch
```

In the browser, open the Portal (`./scripts/tools/show-urls.sh` prints the address and the
test password). Sign in as `alice`. Look at the top of the page: it shows the **version** and
the **pod that answered**, and refreshes every 5 seconds. This is your window into the
cluster.

### Step 2 - Exercise A: upgrade the apps, then roll them back

Build version 2.0.0 and roll it out (terminal 1):

```bash
./scripts/install/21-build-push-images.sh 2.0.0
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

The same thing happens in reverse. `helm rollback` puts the old definition back, and
Kubernetes replaces the pods one by one. **Nobody was offline at any moment.** This is the
easiest kind of rollback, because the apps keep no data of their own.

### Step 3 - Exercise B: one Istio upgrade, with a rollback in the middle

Istio goes from 1.28.1 to 1.29.8. Run the steps one at a time and read what each prints.

```bash
./scripts/upgrade/00-preflight-checks.sh      # is the cluster healthy enough to start?
./scripts/upgrade/01-backup-postgres.sh       # a dump never hurts
./scripts/upgrade/10-istio-precheck.sh        # is this hop allowed? remembers the target
./scripts/upgrade/11-istio-upgrade-crds.sh    # new object definitions (old ones still work)
./scripts/upgrade/12-istio-install-canary.sh  # NEW control plane next to the OLD one
```

Stop here and look. Two control planes are running, and nothing uses the new one yet:

```bash
kubectl get deployments --namespace istio-system --selector app=istiod --label-columns istio.io/rev
```

Now switch:

```bash
./scripts/upgrade/13-istio-switch-tag.sh
./scripts/tools/show-status.sh
```

Read the section "Istio proxy version of every pod" in the status output. **Every pod still
runs the old proxy.** Moving the tag only decides what *new* pods get. So:

```bash
./scripts/upgrade/14-istio-restart-workloads.sh   # pods restart and get the new sidecar
./scripts/upgrade/15-istio-upgrade-gateways.sh    # the gateways are pods too
./scripts/upgrade/16-istio-verify.sh              # every proxy on 1.29.8? services answer?
```

Imagine something looks wrong now. Because the old control plane is still installed, the way
back is one command:

```bash
./scripts/rollback/rollback-istio.sh
```

It points the tag back, restarts the workloads and gateways, and checks that every proxy
runs 1.28.1 again. The new control plane stays installed but unused, so you can try again:

```bash
./scripts/upgrade/13-istio-switch-tag.sh
./scripts/upgrade/14-istio-restart-workloads.sh
./scripts/upgrade/15-istio-upgrade-gateways.sh
./scripts/upgrade/16-istio-verify.sh
./scripts/upgrade/17-istio-remove-old.sh          # only now the easy way back is gone
```

### Step 4 - Read the numbers

```bash
./scripts/tools/availability-probe.sh stop
./scripts/tools/availability-probe.sh report
tail -n 40 logs/steps.log
```

The report shows, per service, how many requests failed and the longest gap. Expect `app1`
and `app2` at or near 100 %. For `keycloak` you may see a few failed requests around step 14:
PostgreSQL is a single pod, and while it restarted Keycloak could not reach its database.
(The probe asks Keycloak for a page it can often answer from memory, so the number may stay
at 100 % - real logins would still have paused for those seconds.) That is the honest cost
of a single pod, and exactly the kind of thing you want to *see* on a test system before
your users see it.

### Step 5 - Finish

`./scripts/upgrade/upgrade-all.sh` does everything that is left. It skips what is already
done. When you have finished playing: `./scripts/destroy/destroy-all.sh`.

### What you just learned

1. **Old and new side by side** beats "replace and hope".
2. **A switch is not a rollout.** Moving a tag (or changing an image) changes nothing until
   pods restart.
3. **Write down the way back before you start** (the scripts store it in `.state/`).
4. **Measure.** The probe turns "I think it was fine" into numbers.
5. **Things without data are easy to roll back. Things with data are not** - Part 3 shows
   how the example deals with that.

---

## Part 2 - The ideas behind it

### An "upgrade" is really four different jobs

| Job | What changes | Who does the work |
| --- | --- | --- |
| Control plane | the Kubernetes API server and its helpers | Azure, when you ask (`az aks upgrade --control-plane-only`) |
| Nodes | the virtual machines that run your pods | Azure replaces them one by one; **your pods must move** |
| Platform add-ons | Istio, storage drivers, ... | you, with Helm |
| Your software and its data | apps, Keycloak, PostgreSQL | you |

They have different risks. The control plane upgrade does not touch running pods. The node
upgrade restarts *every* pod. Add-ons and databases have their own rules.

### How pods survive a node being replaced

1. **Surge**: Azure first adds a fresh node with the new version, so there is room.
2. **Cordon**: the old node is marked "no new pods here".
3. **Drain**: the pods on the old node are asked to leave ("evicted"), one after another.
4. Their controllers (Deployment, StatefulSet) start replacements on other nodes.

Two things keep your service alive during step 3:

- **More than one pod.** With two pods on two nodes, one can leave while the other answers.
- **A PodDisruptionBudget (PDB)**: a rule like "at least 1 pod of this app must stay
  available". The drain waits until the replacement pod is ready before it evicts the next
  one.

And the pods themselves must behave: a **readiness probe** tells Kubernetes when a new pod
can take traffic, and a **graceful shutdown** lets a leaving pod finish its work.

### Rolling, canary, blue/green

- **Rolling**: replace pods a few at a time. Simple. Old and new run together for a short
  while, so they must get along.
- **Canary**: install the new version next to the old one and send only *some* things to it
  first. Istio's "revisions" work like this: two control planes, and you choose which one a
  pod uses.
- **Blue/green**: build a complete second set (green) next to the running one (blue), move
  everything over, keep blue until you are sure. Costs double for a while; going back is
  trivial.

### Rollback, roll forward, and one-way doors

- **Rollback**: go back to the old version.
- **Roll forward**: fix the problem with an even newer version. Sometimes this is the only
  way.
- **One-way door**: a change you cannot undo. In this example there are three:
  1. The AKS control plane version (Azure has no downgrade).
  2. Keycloak rewriting its database tables on the first start of a new version.
  3. Data written to the new PostgreSQL server after the switch (the old server never saw
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
| Apps | Helm revision numbers and the old tag | `scripts/rollback/rollback-apps.sh` | Helm has pruned the revision (it keeps 10) - then the script deploys the old tag again instead | nothing |
| Istio | the old control plane stays installed | `scripts/rollback/rollback-istio.sh` | you run `17-istio-remove-old.sh`; afterwards the script re-installs the old version first (slower, and only if that version still supports your Kubernetes) | nothing |
| Workload nodes (blue/green) | the old node pool stays, cordoned and empty | `scripts/rollback/rollback-nodepool-bluegreen.sh` | you run `24-aks-bluegreen-delete-old-pool.sh` | nothing |
| Workload nodes (surge) | - | not directly; you can add a pool with the previous Kubernetes version while AKS still offers it | - | - |
| AKS control plane | - | **impossible** | at once | - |
| Keycloak | Helm revision, old version, and a database dump taken while Keycloak was stopped | `scripts/rollback/rollback-keycloak.sh` (restore dump, then `helm rollback`) | the dump is deleted | every change in Keycloak since the upgrade (new users, password changes, sessions) |
| PostgreSQL | the old server keeps running with its data, untouched | `scripts/rollback/rollback-postgres.sh` | you run `43-postgres-retire-old.sh --delete` | everything written since the switch |

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

### The one thing you cannot roll back

The AKS control plane. Protect yourself differently:

- Upgrade a test cluster first, with the same versions and the same manifests.
- Upgrade the control plane alone, then wait and watch before you touch the nodes.
- Use blue/green node pools if you want a way back for the nodes.
- Keep everything needed to rebuild in code (this project is exactly that), plus data
  backups outside the cluster.

---

## Part 4 - Gotchas

Each entry: **what goes wrong**, *why*, and what to do. Where the example already handles
it, the place is named.

### Planning and order

1. **Upgrading Kubernetes before Istio breaks the mesh.** *Istio 1.28 does not support
   Kubernetes 1.35.* Upgrade Istio first, hop by hop. Scripts `10` and `20` check the window.
2. **Skipping a minor version is refused.** *AKS only upgrades the control plane to the next
   minor version, and this example moves Istio one minor version at a time too.* Plan each
   hop; `config/versions.env` holds the paths.
3. **There is no "undo" for the control plane.** *AKS cannot downgrade.* Test first.
4. **Starting the next hop before the last one is finished.** *Nodes that fall too far
   behind the control plane are not supported.* Script `20` refuses while any node pool is
   still on the old minor version.
5. **Brand-new ".0" releases.** *The first patch releases often fix upgrade bugs.* Prefer a
   version that has had a patch or two, unless you need a fix urgently.
6. **Old versions run out of support.** *AKS and Istio each support only the last few minor
   versions.* Waiting too long forces several hops in a hurry. Check
   `az aks get-versions --location <region> --output table` and the Istio support page.
7. **Changing several things at once.** *When something breaks you will not know which
   change did it.* One change, one check - that is why there are so many small scripts.

### AKS and nodes

8. **`az aks upgrade` without `--control-plane-only` upgrades control plane *and* all nodes
   in one go.** You lose the chance to check in between. Script `20` always uses the flag.
9. **A PodDisruptionBudget that can never be satisfied blocks the drain.** *`minAvailable: 1`
   on an app with a single pod means "this pod may never be evicted".* The node upgrade hangs
   until the drain timeout and then fails. Use two pods, or no budget for single pods.
   Preflight (`00`) lists every budget that currently allows zero disruptions.
10. **A crashing pod behind a budget blocks the drain too.** *By default an unhealthy pod
    still counts against the budget.* Set `unhealthyPodEvictionPolicy: AlwaysAllow` (done in
    the charts and values files).
11. **No quota for surge nodes.** *An upgrade first adds nodes.* Without free vCPU quota it
    fails right away. Script `01` checks.
12. **Single pods mean downtime when their node goes.** PostgreSQL and the NFS server here.
    Know which ones you have, and use blue/green node pools if you want to choose the moment.
13. **A disk that lives in one zone pins its pod to that zone.** *A normal (LRS) Azure disk
    can only attach to nodes in its own zone.* If the replacement node is elsewhere, the pod
    stays "Pending". The example uses a zone-redundant disk (`Premium_ZRS`) for the NFS
    server.
14. **Draining only some of the old nodes.** *Evicted pods happily land on another old
    node and are evicted again later.* Cordon **all** old nodes first, then drain (script `23`).
15. **Pods that belong to no controller disappear for good.** *A drain deletes them and
    nobody recreates them.* Always use Deployments, StatefulSets or Jobs.
16. **Automatic upgrades surprise you.** They are switched off here so that every change is
    deliberate. In production, use them *with* a planned maintenance window - not at random.
17. **"Kubernetes version" and "node image" are two different upgrades.** Node images get
    security patches far more often (`az aks nodepool upgrade --node-image-only`). Plan both.
18. **Deprecated Kubernetes APIs can stop a minor upgrade.** AKS checks whether you still use
    APIs that the next version removes, and refuses. Fix the manifests rather than forcing it.
19. **If a node cannot be drained, the upgrade fails by default.** Fix the cause and run the
    same script again; AKS continues where it stopped.

### Istio

20. **Moving the tag changes no running pod.** *Sidecars are added when a pod is created.*
    Restart the workloads (`14`) and check versions (`16`).
21. **Gateways are forgotten.** *They are pods with a proxy too.* Script `15` upgrades their
    chart and restarts them if needed.
22. **Two different injection labels on one namespace.** *`istio-injection=enabled` and
    `istio.io/rev=...` fight each other.* Use only `istio.io/rev` with a tag (see
    `k8s/namespaces.yaml`).
23. **Removing the old control plane too early.** *The webhook that checks Istio objects
    must already point at the new one* (`defaultRevision`), otherwise every `kubectl apply`
    of an Istio object fails. Script `13` moves it before `17` may remove anything.
24. **Downgrading CRDs.** *It can delete fields from existing objects.* On rollback the
    example keeps the newer CRDs; newer definitions work with the older control plane.
25. **`REGISTRY_ONLY` is not a firewall.** *A pod without a sidecar ignores it.* Add
    NetworkPolicies or a firewall if blocking outbound traffic really matters.
26. **The egress gateway cannot look inside HTTPS.** *The example passes TLS through
    untouched*, so the gateway sees only the host name. It also cannot tell *which* pod is
    calling. Good enough to show the idea; real control needs more (see 25).
27. **Putting the NFS server into the mesh.** *Nodes mount NFS, and nodes have no sidecar* -
    with strict mutual TLS the mount would fail. The `nfs-storage` namespace has no injection
    label.
28. **Keycloak's cluster traffic through the sidecar.** *Keycloak pods talk to each other on
    ports 7800 and 57800 with their own protocol.* The chart excludes these ports from the
    sidecar (pod annotations).
29. **Adding `appProtocol` to the gateway Service on Azure.** *The Azure load balancer then
    switches its health check from "is the port open" to an HTTP request for `/`*, which the
    gateway answers with an error - and the load balancer takes the gateway out of service.
    Leave the Service ports as the chart ships them.
30. **Using an old `istioctl`.** Its checks belong to its own version. Script `10` downloads
    the one matching the target.

### Helm

31. **Helm 4 renamed and changed things.** `--atomic` is now `--rollback-on-failure`, and
    Helm 4 applies manifests "server-side" by default. The scripts detect the Helm version.
32. **Server-side apply and Istio's webhooks.** *istiod edits its own webhook objects after
    the install.* With server-side apply, a later `helm upgrade` of an Istio chart can fail
    with a "conflict". The example installs Istio charts with `--server-side=false` on
    Helm 4. (This comes from reading the charts, not from a reproduced failure.)
33. **`--set image.tag=18.10` pulls the wrong image.** *Helm reads it as the number 18.1.*
    Use `--set-string` for tags (see `deploy_postgres`).
34. **`--reuse-values` hides new defaults.** Pass the complete values on every upgrade, as
    the deploy functions do.
35. **Helm remembers only the last 10 revisions.** A rollback target can be gone. The
    rollback scripts then deploy the old version again.
36. **Changing Helm-managed objects with `kubectl scale` or `kubectl edit`.** *Helm does not
    know, and the next upgrade quietly reverts it - or conflicts.* The example scales
    Keycloak through Helm (`--set replicaCount=0`).
37. **`helm rollback` restores definitions, not data.** It will not un-migrate a database.
38. **`helm uninstall` does not delete the volumes of a StatefulSet.** Good (your data
    survives), but they keep costing money until you delete the claims.

### Keycloak

39. **Rolling update across versions.** *Old and new Keycloak pods cannot share one cluster,
    and the new one changes the database.* Stop all old pods, back up, start the new version
    (script `30`, update strategy `Recreate`). Recent Keycloak versions can roll between
    *patch* releases of the same minor version - check the release notes; for anything bigger,
    stop first.
40. **The database migration is a one-way door.** The dump taken in script `30` is the only
    way back.
41. **A failed start after the migration.** Helm puts the previous release back (zero pods),
    but the database may already be changed. Run `rollback-keycloak.sh`; it restores the dump.
42. **Old option names stop working.** Between 24 and 26: `KC_PROXY=edge` became
    `KC_PROXY_HEADERS=xforwarded`; `KC_HOSTNAME_URL` became `KC_HOSTNAME` (a full URL);
    `KEYCLOAK_ADMIN` became `KC_BOOTSTRAP_ADMIN_USERNAME`; health checks moved to port 9000.
    That is why there are two values files in `helm/values/`.
43. **Health probes on the wrong port.** *New pods never become ready and the upgrade rolls
    back.* The probe port is part of the values file per version.
44. **`--import-realm` only works once.** *An existing realm is not overwritten.* Later
    changes to `demo-realm.json` do nothing; change the realm through Keycloak.
45. **"Issuer does not match."** *Pods reach Keycloak by an internal address, browsers by the
    public one, and the token names the public one.* The apps list the endpoints one by one
    (see `SecurityConfig.java`); Keycloak has a fixed public host name.
46. **"Invalid redirect URI."** *The app thinks its own address is `http://...` because it
    sits behind a proxy that ended TLS.* `server.forward-headers-strategy: native` fixes it.
47. **Logging out of one app does not log you out of the other.** *Each app keeps its own
    session; the example has no back-channel logout.* The Keycloak session is ended, so the
    other app cannot start a *new* login without a password - but its existing session lives
    on until it expires.
48. **Test users that cannot log in by script.** *Keycloak asks users with a missing e-mail
    or name to complete their profile first.* The realm file sets all fields.

### PostgreSQL

49. **A new major version cannot open the old data folder.** Use dump and restore (done
    here), `pg_upgrade`, or replication.
50. **Dumping with the old `pg_dump`.** *Always use the tools of the version you move to.*
    Script `41` runs `pg_dump` in the new pod against the old server.
51. **The PostgreSQL 18 image stores data in a different folder.** *A chart written for 14
    would start 18 with an empty database in the wrong place.* The chart sets `PGDATA`
    explicitly, the same for every version.
52. **Restore fails on owners and permissions.** *Since version 15 the `public` schema has
    different default rights.* Restore with `--no-owner --no-acl` as the application role.
53. **Changing the Service while clients are connected.** *Open connections stay with the
    old server.* Stop the clients first - script `42` refuses to switch while Keycloak runs.
54. **Slow queries right after a restore.** *The new database has no statistics.* Run
    `ANALYZE` (done in script `41`).
55. **The password in the secret changed, the database did not notice.** *The image reads
    passwords only when it creates the data folder.* Change passwords with SQL afterwards.
56. **Trying to grow the volume through Helm.** *The volume template of a StatefulSet cannot
    be changed.* Resize the claim itself (the StorageClasses allow expansion).
57. **Forgetting the old server.** It still runs after the switch. Park it
    (`43-postgres-retire-old.sh`) once you are sure, delete it (`--delete`) later.

### NFS and shared storage

58. **One NFS pod is one point of failure.** While it moves (often 1 to 2 minutes, the disk
    must be re-attached) every NFS volume stands still. Use Azure Files for production.
59. **"Soft" mounts corrupt data.** *They return errors to programs when the server is slow.*
    The StorageClass mounts `hard`: programs wait instead.
60. **Clients hang long after the NFS pod is back.** *NFS servers have a "grace period"
    after a restart (90 seconds by default).* The values file shortens it to 10.
61. **"Stale file handle" after the NFS pod moved to another node.** *File handles were tied
    to the disk's device number.* `device-based-fsids: false` in the values file avoids it.
62. **A normal disk cannot be shared.** Azure Disk is "one node at a time" (ReadWriteOnce).
    Sharing needs NFS or Azure Files (ReadWriteMany).
63. **`Retain` leaves disks behind.** *Deleting a claim keeps the Azure disk - and its
    bill.* Destroy script `05` switches volumes to `Delete` first.
64. **PostgreSQL on NFS.** It works for a demo. For real workloads use block storage or a
    managed database.

### Apps, sessions and login

65. **Sessions in pod memory.** *When a pod is replaced its sessions are gone.* Single
    sign-on hides most of it, but a half-filled form is lost. Use Spring Session with Redis
    for real applications.
66. **Login fails at random with two pods.** *The pod that started the login must also
    receive the answer.* Sticky sessions (a cookie set by Istio, see `destinationrules.yaml`)
    or shared sessions solve it.
67. **Requests fail for a second when a pod stops.** *The pod exits before the mesh has
    stopped sending to it.* A `preStop` sleep plus graceful shutdown closes the gap.
68. **The image runs on your Mac but not on AKS.** *Apple Silicon builds `arm64`; the nodes
    are `amd64`.* Build with `--platform linux/amd64` (script `21`).
69. **Tailwind from a CDN.** Fine for a demo. For production, build the CSS file.
70. **Forms and JavaScript calls rejected with 403.** *Spring Security protects against
    forged requests.* The page sends the token from the `XSRF-TOKEN` cookie back in the
    `X-XSRF-TOKEN` header.

### Azure network, names and certificates

71. **The load balancer stays "pending".** *The cluster may not use a public IP in your
    resource group until it has the Network Contributor role, and new role assignments take
    a minute or two to work.* Script `07` grants it; Helm waits.
72. **`nip.io` names do not resolve.** *Some company networks block DNS answers that point
    to "odd" addresses.* The scripts do not depend on it (they tell `curl` the IP); for the
    browser add the line that `show-urls.sh` prints to your hosts file.
73. **Certificate warnings, and an expired certificate after 90 days.** *The example uses a
    private CA.* Import `.state/tls/ca.crt`, and run script `14` again to renew.

### Images and registries

74. **Public registries limit pulls.** *A node upgrade restarts every pod, so every image is
    pulled again - on brand-new nodes with empty caches.* Mirror what you depend on into your
    own registry (`scripts/tools/mirror-images-to-acr.sh`).
75. **`latest` tags.** *A restart can silently bring a different version.* Pin exact versions
    everywhere, as `config/versions.env` does.

### Scripts and tools

76. **`kubectl` talks to the wrong cluster.** *It uses whatever your kubeconfig points at.*
    The scripts use their own file, `.state/kubeconfig`.
77. **Passwords in command lines end up in logs and process lists.** The scripts pass them
    through files or standard input.
78. **Comparing versions as text.** *"1.10" sorts before "1.9".* The scripts use `sort -V`.
79. **`kubectl wait --for=delete` fails when there is nothing to wait for.** The scripts use
    a small loop instead (`wait_pods_gone`).
80. **macOS ships a very old bash (3.2).** Empty lists trip `set -u` there. The scripts use a
    form that works on both.
81. **A `kubectl` much older or newer than the cluster.** Stay within one minor version.

### Terraform

82. **Custom resources cannot be planned before their definitions exist.** That is why the
    Terraform example has layers: Istio's CRDs come from layer 2, Istio objects from layer 3.
83. **Terraform describes the end state; it does not move data.** The database copy is a
    script you run between two applies (`terraform/scripts/postgres-migrate.sh`).
84. **The state file contains secrets** (cluster credentials, generated passwords). Keep it
    private; use a remote backend with encryption for real work.
85. **Raising `kubernetes_version` does not upgrade the nodes.** Node pools have their own
    version argument - which is what lets you upgrade in two deliberate steps.
86. **Mixing tools.** Do not run the shell upgrade scripts against the Terraform-built
    cluster: Terraform would see the difference and try to undo it.

---

## Part 5 - Your options, with pros and cons

### Replacing nodes

| Option | Pros | Cons | Choose when |
| --- | --- | --- | --- |
| **Surge upgrade in place** (`21`) | one command; little extra cost (one extra node at a time) | no real way back; you do not control when a given pod moves | most upgrades; stateless workloads |
| **Blue/green node pool** (`22`-`24`) | old nodes untouched until you delete them; you pick the moment; trivial way back | needs double quota and money for a while; more steps | risky upgrades; sensitive single pods |
| **A whole new cluster** | even the control plane has a way back | a lot of work: data, addresses and certificates must move | big jumps; when you cannot afford any surprise |

### Upgrading Istio

| Option | Pros | Cons |
| --- | --- | --- |
| **Canary with revisions and a tag** (this example) | old and new side by side; you decide when each workload switches; fast way back | more moving parts; you must restart workloads and remember the gateways |
| **In-place** (replace the one control plane) | fewer steps | no way back except installing the old version again; everything switches at once |

### Upgrading PostgreSQL to a new major version

| Option | Pause for users | Way back | Effort |
| --- | --- | --- | --- |
| **Dump and restore into a new server** (this example) | the whole copy time (minutes here, hours for big data) | excellent: the old server is untouched | low |
| **`pg_upgrade` in place** | short | only with a file-system copy or snapshot taken before | medium; trickier in containers (both versions' programs are needed) |
| **Logical replication to a new server** | seconds (only the switch) | good until you stop replication | high |
| **Managed service** (Azure Database for PostgreSQL) | handled by Azure, with a planned window | point-in-time restore | lowest day-to-day |

### Shared storage

| Option | Pros | Cons |
| --- | --- | --- |
| **NFS server pod** (default here) | simple; cheap; easy to understand | single pod; pauses when it moves; you run it yourself |
| **Azure Files with NFS** (`STORAGE_BACKEND=azurefiles-nfs`) | Azure keeps it available; nothing to run | minimum share size; not for heavy database use |
| **Azure NetApp Files** | fast, built for this | costly; more setup |

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
| **Keep the old thing running** (control plane, node pool, database server) | instant, safe | costs resources; you must clean up later |
| **Restore a backup** | data | you lose what happened since; test your restores |
| **Roll forward** | when a one-way door is behind you | needs a fix ready |

### Shell scripts or Terraform?

| | Shell scripts (`scripts/`) | Terraform / OpenTofu (`terraform/`) |
| --- | --- | --- |
| Strength | every step visible; good for ordered, one-time actions (copy data, switch, check) | describes the end state; shows a plan before changing; finds drift |
| Weakness | you must write "is it already done?" yourself | cannot move data; needs layers for ordering; state file to protect |
| Typical use | learning, runbooks, migrations | long-lived environments, teams |

Many teams use both: Terraform for *what should exist*, scripts for *the order of a risky
change*.

---

## Part 6 - Best-practice checklist

**Before**

- [ ] Read the release notes and upgrade notes of every version on your path.
- [ ] Check the compatibility windows (Kubernetes with Istio, application with database).
- [ ] Do the whole upgrade on a test system that matches production.
- [ ] Every important service has two or more pods, a PodDisruptionBudget, probes and a
      graceful shutdown.
- [ ] No budget currently allows zero disruptions (`00-preflight-checks.sh`).
- [ ] Enough quota for surge nodes.
- [ ] Fresh backups of all data - and you have restored one at least once.
- [ ] Images you depend on are in your own registry.
- [ ] You wrote down, per step, how to go back and when that way closes.
- [ ] People know when it happens (a maintenance window for the parts that pause).

**During**

- [ ] One change at a time. Check after each (`24-smoke-test.sh`, `test-login.sh`).
- [ ] Watch real user traffic or a probe, not only "pods are Running".
- [ ] Control plane first, then nodes. Istio before Kubernetes when the window demands it.
- [ ] Keep the old version until the new one is proven (control plane, node pool, database).
- [ ] If something is odd: stop, look at the log, decide. Do not push on.

**After**

- [ ] Verify versions everywhere (`60-post-upgrade-verify.sh`).
- [ ] Read the availability report. Write down what paused and for how long.
- [ ] Clean up: old control plane, old node pool, old database server, old images.
- [ ] Update your notes for next time - you will do this again in a few months.

---

## Part 7 - Small dictionary

| Word | Meaning |
| --- | --- |
| **AKS** | Azure Kubernetes Service: Azure runs the Kubernetes control plane for you. |
| **Control plane** | The "brain" of Kubernetes: the API server and its helpers. |
| **Node / node pool** | A virtual machine that runs pods / a group of equal nodes. |
| **Pod** | The smallest unit Kubernetes runs: one or more containers together. |
| **Deployment / StatefulSet** | Controllers that keep a wanted number of pods running (StatefulSet: with fixed names and their own volumes). |
| **Drain / cordon** | Ask all pods to leave a node / mark a node so that no new pods land on it. |
| **Surge** | Extra nodes (or pods) added first, so capacity does not drop during a change. |
| **PodDisruptionBudget (PDB)** | A rule that limits how many pods of an app may be taken away at once. |
| **Probe** | A check Kubernetes runs on a pod: started? ready for traffic? still alive? |
| **Helm / chart / release / revision** | A package manager for Kubernetes / a package / one installed copy of it / a numbered version of that copy. |
| **Istio / service mesh** | Software that puts a small proxy next to every pod to encrypt, route and control traffic. |
| **Sidecar** | That small proxy container inside each pod. |
| **Ingress / egress gateway** | The proxies at the door: for traffic coming in / going out. |
| **Revision (Istio) / revision tag** | One installed Istio control plane version / a movable name (here `stable`) that points at one. |
| **Canary** | Trying the new version next to the old one before switching everything. |
| **Blue/green** | Building a full second copy, switching over, keeping the old one for a while. |
| **Mutual TLS (mTLS)** | Encryption where both sides prove who they are. |
| **OIDC / single sign-on** | A standard way to log in through a central service (here Keycloak) / one login for several apps. |
| **Realm / client** | In Keycloak: a space with its own users / an application that may ask for logins. |
| **NFS / ReadWriteMany** | A network file system / a volume many pods can mount at the same time. |
| **PV / PVC / StorageClass** | A piece of storage / a request for storage / a recipe for creating storage. |
| **Dump / restore** | Write a database into a file / load it back from the file. |
| **Rollback / roll forward** | Go back to the old version / fix by going to an even newer one. |
| **CRD** | Custom Resource Definition: teaches Kubernetes a new kind of object (for example Istio's `VirtualService`). |
| **Terraform / OpenTofu** | Tools that create infrastructure from files that describe the wanted end state. |
