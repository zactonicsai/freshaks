# AKS → Terraform import & teardown toolkit

Shell scripts that use the **Azure CLI**, **kubectl**, **helm** and **Terraform** to

1. **discover** everything that belongs to an existing AKS environment,
2. **import** it into Terraform state — one script per Azure service, plus disks, networking and the workloads/Helm releases running inside the cluster — so Terraform can manage and destroy it, and
3. **destroy** it again, either through Terraform (`terraform destroy`, staged in dependency order) or directly with `az`, `kubectl` and `helm`.

Every script is heavily commented; this README explains the Azure services involved, what each script does, and what every `az`, `kubectl`, `helm` and `terraform` command in them is for.

---

## Contents

- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Configuration (`config.env`)](#configuration-configenv)
- [The Azure services in an AKS environment](#the-azure-services-in-an-aks-environment)
- [The node resource group — read this before importing](#the-node-resource-group--read-this-before-importing)
- [Workflow A — import the existing cluster into Terraform](#workflow-a--import-the-existing-cluster-into-terraform)
- [Workflow B — destroy with Terraform](#workflow-b--destroy-with-terraform)
- [Workflow C — destroy with az / kubectl / helm](#workflow-c--destroy-with-az--kubectl--helm)
- [Script reference](#script-reference)
  - [lib/common.sh](#libcommonsh--shared-library)
  - [discover/](#discover00-discoversh)
  - [import/](#import-scripts)
  - [destroy/](#destroy-scripts)
- [Command reference](#command-reference)
  - [Azure CLI](#azure-cli-az)
  - [kubectl](#kubectl)
  - [helm](#helm)
  - [terraform](#terraform)
- [Terraform module (`terraform/`)](#terraform-module-terraform)
- [Safety notes and gotchas](#safety-notes-and-gotchas)
- [Troubleshooting](#troubleshooting)

---

## How it works

```
                 ┌────────────────────────────────────────────────────────────┐
  az / kubectl   │  import/NN-import-<service>.sh                              │
  helm (read)    │   1. list the real objects   (az ... list, kubectl get ...) │
 ───────────────►│   2. write  terraform/imports/<service>.tf                  │
                 │          import { to = <type>.<name>  id = "<azure id>" }   │
                 │   3. terraform plan -generate-config-out=generated/<svc>.tf │
                 │          → Terraform writes the resource {} blocks           │
                 └──────────────────────────┬─────────────────────────────────┘
                                            │
                 ┌──────────────────────────▼─────────────────────────────────┐
                 │  import/90-apply-imports.sh                                 │
                 │   terraform plan  → "N to import, 0 to add, 0 to change"    │
                 │   terraform apply → STATE IS CREATED, Azure is untouched    │
                 │   import blocks archived (they are one-shot)                │
                 └──────────────────────────┬─────────────────────────────────┘
                                            │
            ┌───────────────────────────────┴──────────────────────────────┐
            ▼                                                              ▼
  destroy/terraform-destroy.sh                               destroy/destroy-all.sh
  staged `terraform destroy -target=...`                      helm uninstall → kubectl delete
  workloads → node pools → cluster → disks →                  → az aks delete → az group delete
  services → networking → resource group                      (or per-service az scripts)
```

The import scripts never run `terraform import` themselves. They write Terraform ≥ 1.5 **`import {}` blocks** and let `terraform plan -generate-config-out` produce the HCL, which is far less error-prone than hand-writing hundreds of resource blocks. A parallel list of classic `terraform import ADDR ID` commands is still written to `out/import-commands/<service>.sh` for anyone who prefers that flow.

---

## Repository layout

```
aks-terraform-import/
├── README.md                      ← this file
├── config.env.example             ← copy to config.env and edit (never committed)
├── .gitignore
├── lib/
│   └── common.sh                  ← shared helpers: config, logging, az/kubectl checks, import-block writer
├── discover/
│   └── 00-discover.sh             ← read-only inventory → out/inventory.md + .json
├── import/                        ← one script per service, each writes terraform/imports/<service>.tf
│   ├── 01-import-resource-group.sh
│   ├── 02-import-networking.sh    ← VNet, subnets, NSGs, route tables, public IPs, LBs, NAT, DNS, private endpoints, App GW
│   ├── 03-import-identity.sh      ← managed identities, federated credentials, role assignments
│   ├── 04-import-aks-cluster.sh   ← the cluster, extra node pools, extensions (+ writes the kubeconfig)
│   ├── 05-import-disks.sh         ← managed disks (PVC-backed and static), snapshots, PV↔disk map
│   ├── 06-import-storage.sh       ← storage accounts (+ Azure Files shares, opt-in)
│   ├── 07-import-acr.sh           ← container registries, incl. ones attached to the cluster
│   ├── 08-import-keyvault.sh      ← key vaults (+ secrets, opt-in)
│   ├── 09-import-monitoring.sh    ← Log Analytics, diagnostic settings, DCRs, Monitor workspace, Grafana, alerts
│   ├── 10-import-kubernetes-deployments.sh ← namespaces, deployments, services, ingresses, configmaps, PVCs, HPAs ...
│   ├── 11-import-helm-releases.sh ← helm_release blocks + exported values
│   ├── import-all.sh              ← runs 01..11
│   ├── 90-apply-imports.sh        ← terraform init / validate / plan / apply → state
│   └── 95-verify.sh               ← terraform plan -detailed-exitcode (must be 0)
├── destroy/
│   ├── terraform-destroy.sh       ← staged terraform destroy (Workflow B)
│   ├── 01-destroy-kubernetes-workloads.sh ← helm uninstall, kubectl delete (ordered)
│   ├── 02-destroy-aks-cluster.sh  ← az aks delete (+ node RG)
│   ├── 03-destroy-disks.sh        ← az disk / snapshot delete
│   ├── 04-destroy-networking.sh   ← az network ... delete, in dependency order
│   ├── 05-destroy-platform-services.sh ← ACR, Key Vault, storage, monitoring, identities
│   ├── 06-destroy-resource-group.sh ← az group delete
│   ├── destroy-all.sh             ← runs the CLI path end-to-end (Workflow C)
│   └── 90-reset-terraform-state.sh ← drop stale state after a CLI teardown
├── terraform/                     ← the root module the state lives in
│   ├── versions.tf                ← terraform ≥ 1.5, azurerm ~> 4, kubernetes ~> 2, helm ~> 2
│   ├── providers.tf               ← azurerm features, kubernetes/helm via kubeconfig
│   ├── variables.tf
│   ├── backend.tf                 ← local state by default; azurerm backend example
│   ├── imports/                   ← generated: import {} blocks        (one-shot)
│   ├── generated/                 ← generated: resource {} blocks      (review these!)
│   └── helm-values/               ← generated: values.yaml per Helm release
└── out/                           ← generated: inventory, kubeconfig, logs, CSVs, backups
```

---

## Prerequisites

| Tool | Version | Why |
|---|---|---|
| bash | 3.2+ (4+ recommended) | scripts are written to run on macOS's default bash too |
| Azure CLI (`az`) | 2.60+ | every Azure read and delete; extensions `k8s-extension`, `amg`, `log-analytics-solution` are auto-installed on first use |
| `kubectl` | matching the cluster | reads workloads / PVs, deletes workloads |
| `kubelogin` | any | only for clusters with Entra ID (AAD) authentication and no local accounts |
| `helm` | 3.13+ | `helm get metadata` splits chart name/version; older versions fall back to parsing |
| `jq` | 1.6+ | all JSON parsing |
| `terraform` | **1.5+** | `import {}` blocks and `plan -generate-config-out` |

Azure permissions: **Reader** on the subscription is enough for discovery and import (role assignments are read with `az role assignment list`, which needs `Microsoft.Authorization/roleAssignments/read`). Destroying needs **Contributor** on the resource group (plus `User Access Administrator` to delete role assignments, and Key Vault data-plane rights to purge).

Log in first:

```bash
az login
az account set --subscription <id>
```

---

## Configuration (`config.env`)

```bash
cp config.env.example config.env
$EDITOR config.env
```

| Variable | Default | Meaning |
|---|---|---|
| `SUBSCRIPTION_ID` | — | **required** |
| `RESOURCE_GROUP` | — | **required** — the group that contains the AKS resource |
| `CLUSTER_NAME` | — | **required** |
| `NODE_RESOURCE_GROUP` | auto (`az aks show`) | the `MC_<rg>_<cluster>_<region>` group AKS owns |
| `LOCATION` | auto (`az group show`) | |
| `INCLUDE_NODE_RG` | `false` | also scan/destroy objects in the node RG — see the warning below |
| `KUBECONFIG_PATH` | `out/kubeconfig` | where `az aks get-credentials` writes; used by kubectl, helm and the Terraform providers |
| `USE_ADMIN_CREDENTIALS` | `false` | `az aks get-credentials --admin` |
| `SYSTEM_NAMESPACES` | kube-system, gatekeeper-system, … | never imported, never deleted |
| `K8S_NAMESPACES` | all non-system | restrict Kubernetes/Helm scripts to these namespaces |
| `IMPORT_SECRETS` | `false` | import `kubernetes_secret_v1` (data lands in state and HCL) |
| `IMPORT_KEYVAULT_SECRETS` | `false` | import `azurerm_key_vault_secret` (values land in state) |
| `IMPORT_FILE_SHARES` | `false` | import `azurerm_storage_share` |
| `HELM_SKIP_RELEASES` | — | `"ns/release ns2/release2"` |
| `HELM_REPO_MAP` | — | `"chart=https://repo chart2=oci://…"` — chart repositories Helm cannot recover |
| `ACR_NAMES` | — | registries outside the RG that belong to this platform |
| `DRY_RUN` | `false` | print every mutating `az`/`kubectl`/`helm`/`terraform` command instead of running it |
| `SKIP_GENERATE` | `false` | write import blocks only, skip `terraform plan -generate-config-out` |

Every variable can also be set for one run: `DRY_RUN=true ./destroy/04-destroy-networking.sh`.

---

## The Azure services in an AKS environment

An AKS cluster is never just one resource. This is what a typical production cluster is made of, where it lives, and which script and Terraform resource type handles it.

| Service | What it is / why it is there | Lives in | Script | Terraform type |
|---|---|---|---|---|
| **Resource group** | Container for everything you created. | — | `01` | `azurerm_resource_group` |
| **Node resource group** (`MC_*`) | A second group **AKS creates and owns**: VM scale sets, the `kubernetes` load balancer, outbound public IPs, agent-pool NSG and route table, kubelet identity, PVC disks. Deleted automatically with the cluster. | — | not imported (see below) | — |
| **Virtual network + subnets** | With Azure CNI every pod gets an IP from the node subnet; with kubenet only nodes do. Usually user-created so it can be shared with other workloads. | your RG | `02` | `azurerm_virtual_network`, `azurerm_subnet` |
| **Network security group** | Stateful L4 firewall rules applied to a subnet (user NSG) or to node NICs (AKS NSG in `MC_*`). | your RG / `MC_*` | `02` | `azurerm_network_security_group` + `azurerm_subnet_network_security_group_association` |
| **Route table** | Required by kubenet (pod CIDR routes per node) and for forced tunnelling through a firewall (UDR). | your RG / `MC_*` | `02` | `azurerm_route_table` + `…_route_table_association` |
| **Public IP addresses** | Front-ends for `LoadBalancer` Services, outbound SNAT IPs, NAT gateway IPs, App Gateway IP. | `MC_*` (AKS-created) / your RG (BYO) | `02` | `azurerm_public_ip` |
| **Load balancer** | The Standard LB named `kubernetes` that the cloud-controller-manager programs for every `Service: LoadBalancer`; also used for outbound SNAT unless NAT gateway / UDR is used. | `MC_*` | `02` (only with `INCLUDE_NODE_RG`) | `azurerm_lb` |
| **NAT gateway** | Scalable outbound SNAT (`outboundType: userAssignedNATGateway`). | your RG | `02` | `azurerm_nat_gateway` + public IP / subnet associations |
| **Private DNS zone** | Private clusters publish the API server's private endpoint in `privatelink.<region>.azmk8s.io`; private endpoints for ACR/Key Vault/Storage use their own `privatelink.*` zones. | your RG / `MC_*` | `02` | `azurerm_private_dns_zone` + `…_virtual_network_link` |
| **Public DNS zone** | Zones managed by external-dns for ingress hostnames. | your RG | `02` | `azurerm_dns_zone` |
| **Private endpoint** | NIC-based private access to ACR / Key Vault / Storage / the API server. | your RG / `MC_*` | `02` | `azurerm_private_endpoint` |
| **Application Gateway** | L7 ingress when the AGIC add-on is used. | your RG | `02` | `azurerm_application_gateway` |
| **Managed identities** | *Control-plane identity*: what the cluster uses to program Azure networking. *Kubelet identity*: what nodes use to pull images and attach disks. *Workload identities*: per-application identities federated with Kubernetes service accounts. | your RG / `MC_*` | `03` | `azurerm_user_assigned_identity`, `azurerm_federated_identity_credential` |
| **Role assignments** | The RBAC grants those identities carry: *Network Contributor* on the VNet, *AcrPull* on registries (`--attach-acr`), *Key Vault Secrets User*, … | any scope | `03`, `07` | `azurerm_role_assignment` |
| **AKS managed cluster** | The control plane plus the embedded `default_node_pool`. | your RG | `04` | `azurerm_kubernetes_cluster` |
| **Node pools** | Extra System/User pools, each a VM scale set in `MC_*`. | your RG (resource) | `04` | `azurerm_kubernetes_cluster_node_pool` |
| **Cluster extensions** | Flux (GitOps), Dapr, Azure ML, … installed through the KubernetesConfiguration RP. | cluster | `04` | `azurerm_kubernetes_cluster_extension` |
| **Managed disks** | Every `PersistentVolumeClaim` on the `managed-csi` / `default` storage classes becomes a managed disk (`pvc-<uuid>`), created by the Azure Disk CSI driver in `MC_*`. Disks of PVs with `reclaimPolicy: Retain` survive cluster deletion. | `MC_*` / your RG | `05` | `azurerm_managed_disk`, `azurerm_snapshot` |
| **Storage accounts** | Azure Files shares behind `azurefile*` PVCs (the File CSI driver auto-creates accounts in `MC_*`), blob storage, Terraform state. | `MC_*` / your RG | `06` | `azurerm_storage_account`, `azurerm_storage_share` |
| **Container registry** | Image source; attached to the cluster by granting AcrPull to the kubelet identity. | your RG / elsewhere | `07` | `azurerm_container_registry` |
| **Key Vault** | Secrets, keys and certificates surfaced into pods by the Secrets Store CSI driver, or used for etcd/disk encryption. Soft-deleted on delete. | your RG | `08` | `azurerm_key_vault`, `azurerm_key_vault_secret` |
| **Log Analytics workspace** | Target of Container Insights (`omsagent`/`ama-logs`) and control-plane diagnostic logs. Often auto-created in `DefaultResourceGroup-*`. | your RG / elsewhere | `09` | `azurerm_log_analytics_workspace`, `azurerm_log_analytics_solution` |
| **Diagnostic settings** | Routes kube-apiserver / kube-audit / … logs to the workspace. | on the cluster | `09` | `azurerm_monitor_diagnostic_setting` |
| **Data collection rules** | How Container Insights and managed Prometheus collect (`MSCI-*`, `MSProm-*`) and the association that binds a rule to the cluster. | your RG | `09` | `azurerm_monitor_data_collection_rule`, `…_association` |
| **Azure Monitor workspace** | Managed Prometheus metrics store. | your RG | `09` | `azurerm_monitor_workspace` |
| **Managed Grafana** | Dashboards on top of the Monitor workspace. | your RG | `09` | `azurerm_dashboard_grafana` |
| **Metric alerts** | Alert rules on cluster metrics. | your RG | `09` | `azurerm_monitor_metric_alert` |
| **Kubernetes objects** | What runs inside: namespaces, Deployments, StatefulSets, DaemonSets, Services, Ingresses, ConfigMaps, Secrets, PVCs, ServiceAccounts, HPAs, CronJobs, custom StorageClasses. | cluster | `10` | `kubernetes_*_v1` |
| **Helm releases** | Charts installed with `helm install` (ingress-nginx, cert-manager, …). Each release's objects are owned by Helm, not imported individually. | cluster | `11` | `helm_release` |

---

## The node resource group — read this before importing

AKS creates `MC_<rg>_<cluster>_<region>` and treats it as its own. The AKS resource provider **continuously reconciles** what is inside it: it adds LB rules when you create a `Service`, scales VM scale sets, rotates public IPs, re-creates its NSG rules.

If you import those objects into Terraform:

- `terraform plan` will show drift forever (AKS keeps changing them),
- `terraform destroy` on, say, the `kubernetes` load balancer breaks every `LoadBalancer` Service,
- and none of it is necessary — **`az aks delete` (or destroying `azurerm_kubernetes_cluster`) deletes the whole node resource group**.

Therefore the scripts default to `INCLUDE_NODE_RG=false` and only touch your own resource group. Two exceptions are handled explicitly:

- **PVC disks** (`05-import-disks.sh`) are found through the PersistentVolumes rather than by resource group, so they are imported wherever they live — these are the objects you really want Terraform to know about, because `Retain` volumes outlive the cluster.
- **Storage accounts behind Azure Files PVs** (`06-import-storage.sh`) are found the same way.

Set `INCLUDE_NODE_RG=true` only when you have orphans to clean up after a failed cluster deletion.

---

## Workflow A — import the existing cluster into Terraform

```bash
# 0. Configure
cp config.env.example config.env && $EDITOR config.env
az login

# 1. Look before you touch anything (writes out/inventory.md)
./discover/00-discover.sh

# 2. Record import blocks + let Terraform generate the HCL — all services …
./import/import-all.sh
#    … or one service at a time:
./import/02-import-networking.sh
./import/05-import-disks.sh

# 3. Review what was generated
ls terraform/imports/      # import {} blocks   — what will be adopted
ls terraform/generated/    # resource {} blocks — what Terraform thinks they look like
$EDITOR terraform/generated/helm_releases.tf   # fill any TODO chart repositories

# 4. Create the state (plan must read "N to import, 0 to add, 0 to change, 0 to destroy")
./import/90-apply-imports.sh

# 5. Prove it: no changes
./import/95-verify.sh
```

What "review" means in step 3: Terraform's generated configuration is a faithful dump of each object, including attributes that are optional-but-computed. Typical edits:

- delete attributes `terraform validate` flags as read-only;
- add `lifecycle { ignore_changes = [...] }` for things controlled by autoscalers (`default_node_pool[0].node_count`, Deployment `spec[0].replicas`) or by Azure Policy (`tags`);
- replace literal IDs with references (`azurerm_subnet.x.id`) if you want Terraform to understand dependencies — optional, but it lets a plain `terraform destroy` order things correctly.

After step 4 the import blocks are archived to `out/imports-applied/`. **Do not put them back**: Terraform re-evaluates import blocks on every plan, and a block whose object has since been deleted makes the plan fail.

---

## Workflow B — destroy with Terraform

```bash
./destroy/terraform-destroy.sh        # prompts for the cluster name
DRY_RUN=true ./destroy/terraform-destroy.sh   # show the stages and targets only
```

Imported resources carry no `depends_on` edges (the generated HCL uses literal IDs), so a plain `terraform destroy` would try to delete a VNet while the cluster still uses it, or a disk a pod still mounts. The script therefore runs targeted destroys in this order, each target list built from `terraform state list`:

| Stage | Targets | Why in this position |
|---|---|---|
| 1 | `helm_release.*`, `kubernetes_*` | needs the cluster alive; releases Azure LBs/IPs/disks cleanly |
| 2 | `azurerm_kubernetes_cluster_node_pool.*` | before the cluster |
| 3 | `azurerm_kubernetes_cluster.*`, `…_extension.*` | Azure deletes the node RG with it |
| 4 | `azurerm_managed_disk.*`, `azurerm_snapshot.*` | now detached (or already gone → no-op) |
| 5 | monitoring, ACR, Key Vault, storage, identities, role assignments | no further dependents |
| 6 | subnet/NAT associations, private endpoints, App GW, LBs, DNS links | edge first |
| 7 | NAT gateways, public IPs, DNS zones, NSGs, route tables, subnets, VNets | core last |
| 8 | `azurerm_resource_group.*` | empty by now (`prevent_deletion_if_contains_resources = false` is set in providers.tf) |
| 9 | plain `terraform destroy` | anything not matched above |

---

## Workflow C — destroy with az / kubectl / helm

```bash
./destroy/destroy-all.sh                           # workloads → cluster → resource group
DELETE_RESOURCE_GROUP=false ./destroy/destroy-all.sh   # workloads → cluster → disks → networking → services, keep the empty RG
DRY_RUN=true ./destroy/destroy-all.sh              # print every command
# or step by step:
./destroy/01-destroy-kubernetes-workloads.sh
./destroy/02-destroy-aks-cluster.sh
./destroy/03-destroy-disks.sh
./destroy/04-destroy-networking.sh
./destroy/05-destroy-platform-services.sh
./destroy/06-destroy-resource-group.sh
./destroy/90-reset-terraform-state.sh              # afterwards, if a Terraform state exists
```

Every destructive script asks you to type the cluster (or group) name; `CONFIRM=yes` skips the prompt for automation. Failures are reported and the script continues, so re-running after fixing a dependency is safe.

---

## Script reference

### `lib/common.sh` — shared library

Sourced by every script; never run directly.

| Function | What it does |
|---|---|
| `load_config` | sources `config.env`, validates the three required variables, applies defaults, exports `KUBECONFIG` |
| `require_tools a b c` | aborts with a clear message if a CLI is missing |
| `az_check` | `az account show` (logged in?), `az account set` (pin subscription), `az group show --query location`, `az aks show --query nodeResourceGroup` (find `MC_*`) |
| `aks_credentials` | `az aks get-credentials --file $KUBECONFIG_PATH --overwrite-existing [--admin]`, `kubelogin convert-kubeconfig -l azurecli` (Entra ID clusters), `kubectl cluster-info` (connectivity check) |
| `run cmd…` | runs the command, or prints it when `DRY_RUN=true` — every mutating command goes through this |
| `tf_name` | turns `pvc-1234.disk` into a legal Terraform label `pvc_1234_disk` |
| `tf_import_begin <service>` | truncates `terraform/imports/<service>.tf`, `out/import-commands/<service>.sh`, drops old rows for the service from `out/imports.csv`, writes `terraform.tfvars` |
| `tf_import_add <type> <label> <id> [comment]` | appends one `import {}` block, one `terraform import` command and one CSV row; skips addresses already recorded (idempotent re-runs) |
| `tf_import_end` | counts blocks, removes empty files, calls `tf_generate` |
| `tf_generate <service>` | `terraform init` (once) + `terraform plan -generate-config-out=generated/<service>.tf`; non-fatal on failure, log in `out/plan-<service>.log` |
| `archive_import_blocks` | moves `imports/*.tf` to `out/imports-applied/<ts>/` after they have been applied |
| `is_system_ns`, `target_namespaces` | namespace filtering shared by the Kubernetes/Helm scripts |
| `confirm <text>` | the type-the-name guard used by every destroy script |

### `discover/00-discover.sh`

Read-only. Collects the cluster definition, node pools, every resource in both resource groups (`az resource list`), namespaces, Helm releases, PersistentVolumes with their Azure handles, `LoadBalancer` Services, Ingresses and workloads, then writes `out/inventory.md` (tables) and `out/inventory.json`. Run it first and keep the output — it is the "before" picture.

### Import scripts

All import scripts follow the same shape: `load_config → az_check → tf_import_begin <service> → list objects with az/kubectl/helm → tf_import_add … → tf_import_end`. They only **read** from Azure and the cluster.

| Script | Service | Finds | Notes |
|---|---|---|---|
| `01-import-resource-group.sh` | `resource_group` | `az group show` | the node RG is deliberately not imported |
| `02-import-networking.sh` | `networking` | VNets → subnets → NSG/route-table/NAT associations; NSGs; route tables; public IPs; LBs; NAT gateways + IP associations; private DNS zones + links; DNS zones; private endpoints; App Gateways | association resources use the **subnet ID** as import ID; NAT/IP association uses `natgw-id\|pip-id` |
| `03-import-identity.sh` | `identity` | user-assigned identities, their federated credentials, and the role assignments of: each identity, the cluster control-plane identity, the kubelet identity | uses `az role assignment list --assignee <principal> --all`; AKS-created assignments (AcrPull via `--attach-acr`) are included so Terraform can remove them |
| `04-import-aks-cluster.sh` | `aks_cluster` | the cluster, non-default node pools, cluster extensions; writes the kubeconfig | the first System-mode pool is the provider's `default_node_pool` and is **not** imported separately |
| `05-import-disks.sh` | `disks` | disks behind PVs (`PV.spec.csi.volumeHandle`), data disks in the RG (+ node RG opt-in), snapshots; writes `out/disk-map.csv` | OS disks are skipped; attached disks are imported with a note |
| `06-import-storage.sh` | `storage` | storage accounts in the RG and accounts behind Azure Files PVs (`volumeHandle = rg#account#share#…`); shares opt-in | share import ID is the data-plane URL `https://<acct>.file.core.windows.net/<share>` |
| `07-import-acr.sh` | `acr` | registries in the RG, registries with an AcrPull grant for the kubelet identity, `ACR_NAMES` | |
| `08-import-keyvault.sh` | `keyvault` | vaults in the RG; secrets opt-in (versioned URL via `az keyvault secret show`) | access policies are generated inline |
| `09-import-monitoring.sh` | `monitoring` | Log Analytics workspaces (+ the Container Insights one if it is in the RG), solutions, diagnostic settings on the cluster, DCRs and their associations, Monitor workspaces, Grafana, metric alerts | diagnostic setting import ID is `<cluster id>\|<name>` |
| `10-import-kubernetes-deployments.sh` | `kubernetes` | per non-system namespace: the namespace, deployments, statefulsets, daemonsets, services, ingresses, configmaps, secrets (opt-in), PVCs, serviceaccounts, HPAs, cronjobs; plus custom storage classes | skips Helm-managed objects (label `app.kubernetes.io/managed-by=Helm` / annotation `meta.helm.sh/release-name`), controller-owned objects (`ownerReferences`), and API-server managed defaults |
| `11-import-helm-releases.sh` | `helm` | every release outside system namespaces; writes `generated/helm_releases.tf` and `helm-values/<ns>__<release>.yaml` itself | Helm does not store the chart repository — guessed from `helm search repo`, then `HELM_REPO_MAP`, else `TODO` |
| `import-all.sh` | — | runs 01–11; `SKIP_STEPS="07 08"` to skip | |
| `90-apply-imports.sh` | — | `terraform init`, `validate`, `plan -out`, confirmation, `apply`, archive import blocks, `plan -detailed-exitcode` | `AUTO_APPROVE=true` for CI |
| `95-verify.sh` | — | state count by type vs `out/imports.csv`; `terraform plan -detailed-exitcode` | exit 0 = state matches reality |

### Destroy scripts

| Script | Tooling | Order of operations | Options |
|---|---|---|---|
| `terraform-destroy.sh` | terraform | the 9 stages in [Workflow B](#workflow-b--destroy-with-terraform) | `DRY_RUN`, `CONFIRM` |
| `01-destroy-kubernetes-workloads.sh` | helm, kubectl | 1 `helm uninstall --wait` each release → 2 delete `LoadBalancer` Services (Azure removes LB rules + public IPs) → 3 delete Ingresses → 4 delete PVCs (CSI deletes `Delete` disks) → 5 delete namespaces (`default` is emptied) → 6 wait for released PVs, report `Retain` volumes | `HELM_TIMEOUT`, `NS_DELETE_TIMEOUT`, `FORCE_NAMESPACE_FINALIZERS`, `DELETE_RETAINED_PVS` |
| `02-destroy-aks-cluster.sh` | az | `az aks delete --no-wait` → `az aks wait --deleted` → check the node RG is gone | `DELETE_NODE_RG` |
| `03-destroy-disks.sh` | az | unattached data disks (`az disk delete --no-wait` + `az disk wait --deleted`), snapshots; attached and OS disks are skipped | `INCLUDE_NODE_RG` |
| `04-destroy-networking.sh` | az | App GW → private endpoints → LBs → NAT gateways (detach from subnets first) → public IPs → private DNS links/zones, DNS zones → subnets (detach NSG/route table first) → NSGs, route tables → VNets | `INCLUDE_NODE_RG` |
| `05-destroy-platform-services.sh` | az | alerts → DCR associations → DCRs → solutions → Grafana → Monitor workspaces → Log Analytics (`--force`) → ACR → Key Vault (delete + purge) → storage → role assignments → identities | `PURGE_KEYVAULT`, `KEEP_LOG_ANALYTICS` |
| `06-destroy-resource-group.sh` | az | refuses while the cluster exists (orphaned node RG), checks locks, `az group delete --no-wait` + `az group wait --deleted` | `DELETE_LOCKS`, `FORCE_RG_DELETE` |
| `destroy-all.sh` | all | 01 → 02 → 06, or 01 → 02 → 03 → 04 → 05 with `DELETE_RESOURCE_GROUP=false` | `SKIP_STEPS`, `DRY_RUN`, `CONFIRM` |
| `90-reset-terraform-state.sh` | terraform | `terraform state pull` backup → `terraform state rm` every address → archive `generated/`, `imports/`, `helm-values/` | run after a CLI teardown so Terraform does not try to recreate everything |

---

## Command reference

### Azure CLI (`az`)

All `list`/`show` commands are read-only and are used by the import and discover scripts; `delete`/`update`/`purge` are used by the destroy scripts and always go through `run` (so `DRY_RUN=true` prints them).

| Command | What it does | Used by |
|---|---|---|
| `az login` / `az account show` | authenticate / prove a token exists | you / `az_check` |
| `az account set --subscription <id>` | make every later command use this subscription | `az_check` |
| `az group show -n <rg>` | resource group ID and location | 01, `az_check` |
| `az group exists -n <rg>` | `true`/`false` — used to detect a leftover node RG | 02–06 |
| `az group delete -n <rg> --yes --no-wait` | delete the group and everything in it, return immediately | 02 (node RG), 06 |
| `az group wait -n <rg> --deleted` | block until the group is gone | 02, 06 |
| `az lock list -g <rg>` / `az lock delete --ids <id>` | management locks block deletion; list / remove them | 06 |
| `az resource list -g <rg>` | every resource in a group (type + name) — the inventory | 00, 06 |
| `az aks show -g <rg> -n <cluster>` | cluster JSON: ID, version, node RG, network profile, identities, add-ons | many |
| `az aks nodepool list -g <rg> --cluster-name <c>` | every agent pool with `mode` (System/User), size, count | 00, 04 |
| `az aks get-credentials -g <rg> -n <c> --file <path> --overwrite-existing [--admin]` | write a kubeconfig; `--admin` uses the cluster-admin certificate instead of Entra ID | `aks_credentials` |
| `az aks delete -g <rg> -n <c> --yes --no-wait` | delete the cluster **and its node resource group** | 02 |
| `az aks wait -g <rg> -n <c> --deleted --timeout 3600` | poll until the cluster no longer exists | 02 |
| `az k8s-extension list -g <rg> -c <c> -t managedClusters` | cluster extensions (Flux, Dapr…) | 04 |
| `az network vnet list -g <rg>` | virtual networks | 02, 04-destroy |
| `az network vnet subnet list -g <rg> --vnet-name <v>` | subnets with their NSG / route table / NAT gateway links and `ipConfigurations` (in-use indicator) | 02, 04-destroy |
| `az network vnet subnet update … --remove natGateway` / `--remove networkSecurityGroup` / `--remove routeTable` | detach a link so the linked object can be deleted | 04-destroy |
| `az network vnet subnet delete` / `az network vnet delete` | delete subnet / VNet (fails while NICs or delegations remain) | 04-destroy |
| `az network nsg list/delete` | network security groups | 02, 04-destroy |
| `az network route-table list/delete` | route tables | 02, 04-destroy |
| `az network public-ip list/delete` | public IP addresses (delete fails while attached) | 02, 04-destroy |
| `az network lb list/delete` | load balancers | 02, 04-destroy |
| `az network nat gateway list/delete` | NAT gateways (JSON includes attached public IPs) | 02, 04-destroy |
| `az network private-dns zone list/delete`, `az network private-dns link vnet list/delete -z <zone>` | private DNS zones and their VNet links | 02, 04-destroy |
| `az network dns zone list/delete` | public DNS zones | 02, 04-destroy |
| `az network private-endpoint list/delete` | private endpoints | 02, 04-destroy |
| `az network application-gateway list/delete` | application gateways | 02, 04-destroy |
| `az identity list -g <rg>` / `az identity delete` | user-assigned managed identities (`principalId` is what role assignments reference) | 03, 05-destroy |
| `az identity federated-credential list -g <rg> --identity-name <n>` | workload-identity federations | 03 |
| `az role assignment list --assignee <principalId> --all` | every role assignment of a principal at every scope in the subscription | 03, 07, 05-destroy |
| `az role assignment delete --ids <id>` | remove one assignment | 05-destroy |
| `az disk list -g <rg>` | managed disks: `osType` (set = OS disk), `managedBy` (set = attached), size, SKU | 05, 03-destroy |
| `az disk delete --ids <id> --yes --no-wait` + `az disk wait --ids <id> --deleted` | delete a disk and wait | 03-destroy |
| `az snapshot list/delete` | disk snapshots | 05, 03-destroy |
| `az storage account list -g <rg>` / `--query "[?name=='x'].id"` | accounts in a group / resolve an account name to its ID | 06 |
| `az storage share-rm list --storage-account <a>` | file shares via the management plane | 06 |
| `az storage account delete -n <a> -g <rg> --yes` | delete an account | 05-destroy |
| `az acr list -g <rg>` / `az acr show -n <n>` / `az acr delete -n <n> --yes` | container registries | 07, 05-destroy |
| `az keyvault list -g <rg> --resource-type vault` | vaults (the `--resource-type` filter excludes managed HSMs) | 08, 05-destroy |
| `az keyvault secret list --vault-name <v>` / `az keyvault secret show … --query id` | secret names / the **versioned** secret URL Terraform needs | 08 |
| `az keyvault delete -n <v>` → `az keyvault purge -n <v> -l <loc>` | soft-delete, then permanently purge (impossible with purge protection) | 05-destroy |
| `az monitor log-analytics workspace list/delete -g <rg> [--force]` | workspaces; `--force` = permanent delete instead of 14-day soft delete | 09, 05-destroy |
| `az monitor log-analytics solution list/delete` | `ContainerInsights(<ws>)` solutions | 09, 05-destroy |
| `az monitor diagnostic-settings list --resource <id>` | diagnostic settings on the cluster | 09 |
| `az monitor data-collection rule list/delete`, `… association list/delete --resource <id>` | DCRs and the links that attach them to the cluster | 09, 05-destroy |
| `az monitor account list/delete` | Azure Monitor workspaces (managed Prometheus) | 09, 05-destroy |
| `az grafana list/delete` | Azure Managed Grafana | 09, 05-destroy |
| `az monitor metrics alert list/delete` | metric alert rules | 09, 05-destroy |

### kubectl

| Command | What it does | Used by |
|---|---|---|
| `kubectl cluster-info` | connectivity / auth check right after the kubeconfig is written | `aks_credentials` |
| `kubectl get ns -o json` | namespace list for scoping | `target_namespaces`, 00 |
| `kubectl get pv -o json` | PersistentVolumes with `spec.csi.volumeHandle` = Azure disk ID or `rg#account#share#…` for Azure Files, `claimRef`, `persistentVolumeReclaimPolicy`, `status.phase` | 00, 05, 06, 01-destroy |
| `kubectl get svc -A -o json` | find `spec.type == LoadBalancer` services (each owns Azure LB rules and a public IP) | 00, 01-destroy |
| `kubectl get <kind> -n <ns> -o json` | objects of one kind with labels, annotations and `ownerReferences` — the import filter needs all three | 10 |
| `kubectl get storageclass -o json` | custom vs AKS-provided (`addonmanager.kubernetes.io/mode` label) storage classes | 10 |
| `kubectl get deploy,sts,ds -A -o json`, `kubectl get ingress -A -o json` | workload inventory | 00 |
| `kubectl delete svc/ingress/pvc <name> -n <ns> --wait=true --timeout=5m` | ordered deletions; `--wait` means the cloud-controller / CSI driver finished its Azure clean-up before the script moves on | 01-destroy |
| `kubectl delete <kind> --all -n <ns>` | empty a kind in a namespace | 01-destroy |
| `kubectl delete namespace <ns> --wait=false` + polling `kubectl get ns <ns>` | start deletion, then wait with a timeout | 01-destroy |
| `kubectl replace --raw /api/v1/namespaces/<ns>/finalize -f -` | force-finalize a namespace stuck in `Terminating` (opt-in) | 01-destroy |
| `kubectl delete pv <name>` | remove a `Retain` PV object (opt-in; the disk stays) | 01-destroy |

### helm

| Command | What it does | Used by |
|---|---|---|
| `helm list -A -o json` | every release in every namespace: name, namespace, `chart` (`name-version`), status | 00, 11, 01-destroy |
| `helm get metadata <rel> -n <ns> -o json` | chart name and version as separate fields (helm ≥ 3.13; older versions fall back to splitting `chart`) | 11 |
| `helm get values <rel> -n <ns> -o yaml` | the values the installer supplied (not the chart defaults) → `helm-values/<ns>__<rel>.yaml` | 11 |
| `helm search repo <chart> --version <v> -o json` + `helm repo list -o json` | best-effort guess of the chart repository URL from the repos configured on this machine | 11 |
| `helm uninstall <rel> -n <ns> --wait --timeout 10m` | delete the release and wait until its objects are gone | 01-destroy |

### terraform

| Command | What it does | Used by |
|---|---|---|
| `terraform init -input=false` | download providers (azurerm, kubernetes, helm), initialise the backend | `tf_generate`, 90, destroy |
| `terraform plan -generate-config-out=generated/<svc>.tf` | read every object named in an `import {}` block that has no `resource {}` yet and **write HCL for it** (the file must not exist) | `tf_generate` |
| `terraform validate` | catch syntax / read-only-attribute problems in the generated HCL | 90 |
| `terraform plan -out=import.tfplan` | preview: must say `N to import, 0 to add, 0 to change, 0 to destroy` | 90 |
| `terraform apply import.tfplan` | execute the imports — **state is written, Azure is not changed** | 90 |
| `terraform plan -detailed-exitcode` | exit 0 = no diff (state == reality), 2 = drift, 1 = error | 90, 95 |
| `terraform state list` | addresses in state; used to build destroy stages and verify counts | 95, destroy |
| `terraform destroy -target=<addr> … -auto-approve` | delete only the targeted resources (and their dependents) | terraform-destroy |
| `terraform destroy -auto-approve` | final sweep | terraform-destroy |
| `terraform state pull` / `terraform state rm <addr>` | back up the state / forget a resource without deleting it | 90-reset |
| `terraform import <addr> <id>` | classic one-at-a-time import; written to `out/import-commands/<svc>.sh` for reference, not executed | — |

---

## Terraform module (`terraform/`)

- `versions.tf` pins Terraform ≥ 1.5 and `azurerm ~> 4.0`, `kubernetes ~> 2.30`, `helm ~> 2.17` (the Helm 3.x provider changed the provider-block syntax).
- `providers.tf`
  - `azurerm` authenticates with your `az login` session; `resource_provider_registrations = "none"` avoids needing subscription-wide rights; `features {}` sets `prevent_deletion_if_contains_resources = false` (so the group can be destroyed), Key Vault purge-on-destroy and Log Analytics permanent delete.
  - `kubernetes` and `helm` read the kubeconfig file at `var.kubeconfig_path` instead of the cluster resource's outputs, so they keep working while the cluster itself is being imported or destroyed.
- `variables.tf` / `terraform.tfvars` — the tfvars file is regenerated from `config.env` by every script.
- `backend.tf` — local state by default. **Move to the azurerm backend before sharing this with a team or importing secrets** (instructions in the file).
- `imports/`, `generated/`, `helm-values/` — written by the scripts; review `generated/` before applying.

---

## Safety notes and gotchas

- **Nothing in Azure changes during Workflow A.** Import scripts only read; `terraform apply` of import blocks only writes state. The plan must say `0 to add, 0 to change, 0 to destroy` — if it doesn't, stop and fix the HCL.
- **Import blocks are one-shot.** After a successful apply they are moved to `out/imports-applied/`. A leftover block whose object was deleted makes every plan fail with *Cannot import non-existent remote object*.
- **Generated HCL needs a human.** `-generate-config-out` is accurate but literal. Expect to delete a few read-only attributes and add `ignore_changes` for autoscaled counts, HPA-managed replicas and policy-added tags. `95-verify.sh` tells you when you are done.
- **Secrets in state.** `IMPORT_SECRETS`, `IMPORT_KEYVAULT_SECRETS` and Helm values (`helm-values/`) can contain credentials; they are written in clear text to HCL and state. Use an encrypted, access-controlled backend, and keep `terraform/helm-values/` out of git (already in `.gitignore`).
- **Helm repositories are not recoverable** from a cluster. Pre-seed `HELM_REPO_MAP` or fill the `TODO`s; `terraform plan` cannot run with a `helm_release` whose chart it cannot locate. OCI charts: `chart = "oci://registry/path/chart"` and no `repository`.
- **Default node pool.** The provider embeds the first System pool as `default_node_pool`; verify the name printed by `04-import-aks-cluster.sh` matches what you expect.
- **Destroy order matters** even with `az`: a public IP cannot be deleted while a LB uses it, a subnet while VMSS NICs live in it, a disk while a VM holds it. The destroy scripts encode the order and tell you what still blocks.
- **Key Vault and Log Analytics soft-delete.** `az keyvault delete` keeps the vault recoverable for 90 days and the name reserved; `05-destroy-platform-services.sh` purges it (`PURGE_KEYVAULT=true`) unless purge protection is on. Log Analytics is deleted permanently with `--force`.
- **Shared resources.** A Log Analytics workspace, VNet, ACR or Key Vault used by *other* systems should not be destroyed with this cluster. The import scripts only take the Container Insights workspace when it is in your RG for exactly this reason; review `out/inventory.md` and prune `terraform/imports/*.tf` before applying.
- **`INCLUDE_NODE_RG=true`** is for cleanup after a failed cluster deletion, not for normal use.
- **Dry-run everything destructive first**: `DRY_RUN=true ./destroy/destroy-all.sh`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Config not found: config.env` | `cp config.env.example config.env` and fill in the three required values |
| `Azure CLI is not logged in` | `az login`, then `az account set --subscription …` |
| `kubectl cannot reach the API server` | private cluster (run from inside the VNet / via `az aks command invoke`), or Entra ID auth without `kubelogin` installed, or try `USE_ADMIN_CREDENTIALS=true` |
| `terraform plan` fails with *Cannot import non-existent remote object* | an import block refers to something already deleted; remove the block (or `archive_import_blocks` ran too early) |
| `terraform plan` fails after `11-import-helm-releases.sh` | a `helm_release` still has `repository = "TODO-…"`; fill it in or set `HELM_REPO_MAP` and re-run the script |
| `generated/<svc>.tf already exists` warning | re-running a script writes only *new* resources to a timestamped file; merge or delete as you like |
| `terraform validate`: *Can't configure a value for "x": its value will be decided automatically* | delete that attribute from `generated/*.tf` — it is read-only |
| `95-verify.sh` exits 2 with `node_count` / `replicas` / `tags` changes | add `lifecycle { ignore_changes = [...] }` to the resource |
| `az network vnet subnet delete` fails: *InUseSubnetCannotBeDeleted* | the cluster (VMSS NICs) or private endpoints still use the subnet — delete them first, then re-run `04-destroy-networking.sh` |
| `az disk delete` fails: *disk is attached* | the VM / pod holding it is still there; `03-destroy-disks.sh` skips attached disks on purpose |
| namespace stuck in `Terminating` | something with a finalizer (an operator CRD, an API service) is gone; `FORCE_NAMESPACE_FINALIZERS=true ./destroy/01-destroy-kubernetes-workloads.sh` |
| `az group delete` fails: *ScopeLocked* | a CanNotDelete lock; `DELETE_LOCKS=true ./destroy/06-destroy-resource-group.sh` |
| node RG still exists after the cluster is gone | wait a few minutes, then `DELETE_NODE_RG=true ./destroy/02-destroy-aks-cluster.sh` |
| after a CLI teardown `terraform plan` wants to create 60 resources | the state and generated config are stale: `./destroy/90-reset-terraform-state.sh` |
