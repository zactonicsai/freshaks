# The same example with Terraform / OpenTofu

This folder builds the system from the main [`README`](../README.md) - AKS, NFS storage,
Istio ingress and egress, PostgreSQL, Keycloak, two Spring Boot apps - with Terraform
instead of shell scripts. Upgrades are **changes to a few variables**, applied one small step
at a time.

It reuses the Helm charts, the values files in `../helm/` and the manifests in `../k8s/`.
There is one definition of every component, whichever tool installs it.

> Checked with `tofu validate` and `tofu fmt` against the real providers (azurerm 5.8,
> kubernetes 3.3, helm 3.3, tls 4.4, random 3.9). **Not applied to a real subscription.**
> Treat the first apply as a test.

## Use a separate copy of the project

The scripts and this folder both keep facts in `../.state/`. Do not run both examples from
the same checkout, and do not run the shell upgrade scripts against a cluster that Terraform
manages - Terraform would see the difference and try to undo it. The default names differ
(`rg-hademotf` here, `rg-hademo` for the scripts), so both can exist in one subscription.

## Three layers

| Layer | Folder | Creates | Why it is separate |
| --- | --- | --- | --- |
| 1 | `01-infra/` | resource group, registry, static public IP, AKS cluster, node pools, role assignments | everything else needs the cluster to exist |
| 2 | `02-platform/` | namespaces, NFS storage, Istio control planes, TLS certificate, gateways | the Kubernetes and Helm providers need the cluster's credentials, which exist only after layer 1 |
| 3 | `03-workloads/` | passwords and secrets, shared volumes, mesh policies and routes, PostgreSQL, Keycloak, the apps | Istio objects are custom resources; Terraform can plan them only when their definitions (installed by layer 2) exist |

Each layer has its own state file (local, in its folder). Layers 2 and 3 read the outputs of
the layers before them with `terraform_remote_state`.

**The state files contain secrets** (cluster credentials, generated passwords). They are
listed in `.gitignore`. For a team, use a remote backend with encryption (an example is in
`01-infra/versions.tf`).

## What you need

- OpenTofu 1.7+ **or** Terraform 1.8+ (the configuration uses provider-defined functions).
  The helper scripts pick `tofu` when it is installed, otherwise `terraform`; set `TF_BIN` to
  choose yourself.
- Azure CLI, signed in: `az login`, and the subscription id in the environment:

  ```bash
  export ARM_SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
  ```

- `kubectl`, `docker` (or `USE_ACR_BUILD=true`), `curl`, `openssl` - as for the scripts.

## Quick start

```bash
./terraform/scripts/apply-all.sh
```

It applies layer 1, builds and pushes the app images, applies layers 2 and 3, and then runs
the same smoke test and login test as the shell example. Each `apply` shows its plan and
waits for "yes" (`ASSUME_YES=true` skips the questions).

By hand, the same thing:

```bash
tofu -chdir=terraform/01-infra init
tofu -chdir=terraform/01-infra apply
./terraform/scripts/build-images.sh 1.0.0
tofu -chdir=terraform/02-platform init
tofu -chdir=terraform/02-platform apply
tofu -chdir=terraform/03-workloads init
tofu -chdir=terraform/03-workloads apply
./terraform/scripts/sync-local-state.sh      # kubeconfig, CA, test password into ../.state
./scripts/install/24-smoke-test.sh
./scripts/tools/test-login.sh
./scripts/tools/show-urls.sh
```

To change variables, copy `terraform.tfvars.example` to `terraform.tfvars` in the layer and
edit it. Every variable has a description in `variables.tf`.

## Helper scripts

| Script | Purpose |
| --- | --- |
| `scripts/apply-all.sh` | everything, in order, with tests at the end |
| `scripts/build-images.sh [TAG]` | build and push both app images to the registry of layer 1 |
| `scripts/sync-local-state.sh` | copy kubeconfig, addresses, CA certificate and test password into `../.state`, so `kubectl` and the tools in `../scripts/tools/` work |
| `scripts/postgres-migrate.sh OLD NEW` | copy the Keycloak database between two PostgreSQL instances |
| `scripts/keycloak-db-restore.sh FILE` | restore a dump (data half of a Keycloak rollback) |
| `scripts/destroy-all.sh [--fast]` | remove everything |

They log like all other scripts (`../logs/`), and every command line has a comment.

---

## Upgrades: change a variable, apply, check

The order is the same as in the main README: **Istio → Kubernetes → Keycloak → PostgreSQL →
apps**, one small step at a time. After each step run `./scripts/install/24-smoke-test.sh`
(and `./scripts/tools/show-status.sh` to see versions).

Start the availability probe first if you want numbers:
`./scripts/tools/availability-probe.sh start` (after `sync-local-state.sh`).

### 1. Istio, one minor version per round (`02-platform`, then `03-workloads`)

For 1.28.1 → 1.29.8 (repeat for 1.30.5 and 1.31.1):

| Step | `02-platform/terraform.tfvars` | Then | What happens |
| --- | --- | --- | --- |
| a | `istio_revisions = ["1.28.1", "1.29.8"]`<br>`istio_active_version = "1.28.1"` | apply layer 2 | CRDs upgraded; new control plane installed next to the old one; nothing uses it |
| b | `istio_revisions = ["1.28.1", "1.29.8"]`<br>`istio_active_version = "1.29.8"` | apply layer 2, **then apply layer 3** | layer 2: namespaces point at the new revision, gateways roll. Layer 3: the pods get a changed annotation and roll, picking up the new sidecar |
| c | check: `./scripts/tools/show-status.sh` - every proxy on 1.29.8? | | |
| d | `istio_revisions = ["1.29.8"]`<br>`istio_active_version = "1.29.8"` | apply layer 2 | old control plane removed |

**Roll back** (before step d): set `istio_active_version` back to `"1.28.1"`, apply layer 2,
then layer 3.

How this differs from the shell scripts: there, namespaces carry a *tag* (`stable`) and a
script moves the tag. Here the label holds the revision itself, because the variable
`istio_active_version` already is the one switch.

### 2. Kubernetes, one minor version per round (`01-infra`)

| Step | `01-infra/terraform.tfvars` | What happens |
| --- | --- | --- |
| a | `kubernetes_version = "1.35"`<br>`node_pool_kubernetes_version = "1.34"` | control plane only; pods keep running. **Cannot be undone.** |
| b | `node_pool_kubernetes_version = "1.35"` | nodes are replaced one by one with a surge node; PodDisruptionBudgets are respected |

Repeat for 1.36. Check first that the active Istio version supports the new Kubernetes
version (Istio 1.31 supports 1.32 to 1.36).

**Blue/green for the workload nodes** instead of step b:

```hcl
# add the new pool, apply
user_node_pools = {
  apps  = { kubernetes_version = "1.34" }
  appsb = { kubernetes_version = "1.35" }
}
```

Then move the pods yourself (`kubectl cordon` all nodes with label `agentpool=apps`, then
`kubectl drain` them one by one), check the apps, remove the `apps` line and apply. The
system pool still needs `node_pool_kubernetes_version = "1.35"`.

### 3. Keycloak 24 → 26 (`03-workloads`)

| Step | Do | Why |
| --- | --- | --- |
| a | `keycloak_replicas = 0`, apply | nothing may write during the backup |
| b | `./scripts/upgrade/01-backup-postgres.sh before-keycloak-26` | the only way back - note the file name it prints |
| c | `keycloak_version = "26.8.0"`<br>`keycloak_replicas = 2`<br>`keycloak_update_strategy = "Recreate"`, apply | new version starts and changes the database tables; the values file with the new option names is picked automatically |
| d | `keycloak_update_strategy = "RollingUpdate"`, apply | back to rolling updates for everyday changes |

**Roll back**: `keycloak_replicas = 0`, apply →
`./terraform/scripts/keycloak-db-restore.sh <file from step b>` →
`keycloak_version = "24.0.5"`, `keycloak_replicas = 2`, apply. Changes made in Keycloak since
step b are lost.

### 4. PostgreSQL 14 → 18 (`03-workloads`)

| Step | Do |
| --- | --- |
| a | add the new instance, apply:<br>`postgres_instances = { postgres-v14 = { version = "14.12" }, postgres-v18 = { version = "18.6" } }` |
| b | `keycloak_replicas = 0`, apply |
| c | `./terraform/scripts/postgres-migrate.sh postgres-v14 postgres-v18` |
| d | `postgres_active_release = "postgres-v18"` and `keycloak_replicas = 2`, apply |
| e | later: park the old one with `postgres-v14 = { version = "14.12", replicas = 0 }`, or remove the line (its volume claim stays; delete it with `kubectl` when you are sure) |

**Roll back** (while `postgres-v14` still exists): `keycloak_replicas = 0`, apply →
`postgres_active_release = "postgres-v14"`, `keycloak_replicas = 2`, apply. Data written
since step d is lost.

### 5. Apps (`03-workloads`)

```bash
./terraform/scripts/build-images.sh 2.0.0
```

Then `app_version = "2.0.0"`, apply: a rolling update. **Roll back**: set it to `"1.0.0"`
and apply.

---

## Destroy

```bash
./terraform/scripts/destroy-all.sh           # layer 3, then 2, then 1
./terraform/scripts/destroy-all.sh --fast    # only layer 1; the cluster takes everything with it
```

If destroying layer 3 or 2 gets stuck (a namespace that will not finish deleting, for
example), use `--fast`: it removes the Azure resources, which is what stops the costs, and
then deletes the leftover state files of layers 2 and 3.

## Things to know

- **`helm_release` uses `atomic = true`**: a failed install or upgrade is rolled back by
  Helm, and the apply fails. Fix the cause and apply again.
- **Raising `kubernetes_version` does not touch the nodes.** That is deliberate; see step 2.
- **Terraform does not move data.** Backups, the database copy and restores are the scripts
  named above, run between two applies.
- **The plan for layer 3 needs a reachable cluster with Istio's CRDs.** If layer 2 is not
  applied yet, planning layer 3 fails with "no matches for kind ..." - apply layer 2 first.
- **Certificates**: layer 2 creates its own private CA. `tofu -chdir=terraform/02-platform
  output -raw ca_certificate_pem > ca.crt` gives you the file to import into a browser. The
  server certificate lasts 90 days; an apply in its last 30 days renews it.
- **Passwords**: `tofu -chdir=terraform/03-workloads output -raw test_user_password` and
  `... keycloak_admin_password`.
