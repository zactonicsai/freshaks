#!/usr/bin/env bash
# =============================================================================
#  import/04-import-aks-cluster.sh — The managed cluster and its node pools
# =============================================================================
#   Azure object                 Terraform resource type               Import ID
#   --------------------------   -----------------------------------   ----------------------------------------------------
#   Managed cluster              azurerm_kubernetes_cluster            .../Microsoft.ContainerService/managedClusters/<name>
#   Extra node pool              azurerm_kubernetes_cluster_node_pool  .../managedClusters/<name>/agentPools/<pool>
#   Cluster extension            azurerm_kubernetes_cluster_extension  .../managedClusters/<name>/providers/Microsoft.KubernetesConfiguration/extensions/<ext>
#
#  Node pools: the azurerm provider models ONE pool inside the cluster resource
#  (the `default_node_pool` block — the first System-mode pool returned by the
#  API) and every other pool as a separate azurerm_kubernetes_cluster_node_pool.
#  This script mirrors that: the first System pool is NOT imported separately.
#
#  Also writes the kubeconfig (needed by every later kubectl / helm step and by
#  the Terraform kubernetes + helm providers).
#
#  Azure CLI commands used:
#     az aks show -g <rg> -n <cluster>                               cluster ARM ID and properties
#     az aks nodepool list -g <rg> --cluster-name <cluster>          every agent pool with its mode
#     az k8s-extension list -g <rg> -c <cluster> -t managedClusters  cluster extensions (Flux, Dapr, ...) — needs the k8s-extension CLI extension
#     az aks get-credentials ... --file <kubeconfig>                 (via aks_credentials) kubeconfig for kubectl/helm/terraform
#  kubectl commands used:
#     kubectl cluster-info                                           (via aks_credentials) connectivity check
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
tf_import_begin aks_cluster

cluster_json="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -o json)"
cluster_id="$(jq -r '.id' <<<"$cluster_json")"
k8s_version="$(jq -r '.kubernetesVersion' <<<"$cluster_json")"

tf_import_add azurerm_kubernetes_cluster "$(tf_name "$CLUSTER_NAME")" "$cluster_id" \
  "AKS cluster $CLUSTER_NAME (Kubernetes $k8s_version, node RG $NODE_RESOURCE_GROUP)"

# --- Node pools ---------------------------------------------------------------
pools_json="$(az aks nodepool list -g "$RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" -o json)"
default_pool="$(jq -r '[.[] | select(.mode == "System")][0].name // empty' <<<"$pools_json")"
if [[ -z "$default_pool" ]]; then
  default_pool="$(jq -r '.[0].name' <<<"$pools_json")"
  warn "No System-mode pool found; treating '$default_pool' as default_node_pool"
fi
log "default_node_pool (embedded in the cluster resource): $default_pool"

while IFS='|' read -r pname pid pmode psize pcount; do
  [[ -z "$pname" ]] && continue
  if [[ "$pname" == "$default_pool" ]]; then continue; fi
  tf_import_add azurerm_kubernetes_cluster_node_pool "$(tf_name "${CLUSTER_NAME}_${pname}")" "$pid" \
    "Node pool $pname (mode $pmode, $psize x $pcount)"
done < <(jq -r '.[] | [.name, .id, .mode, .vmSize, (.count|tostring)] | join("|")' <<<"$pools_json")

# --- Cluster extensions (Flux / GitOps, Dapr, Azure ML, ...) -------------------
ext_json="$(az k8s-extension list -g "$RESOURCE_GROUP" -c "$CLUSTER_NAME" -t managedClusters -o json 2>/dev/null || echo '[]')"
while IFS='|' read -r ename eid etype; do
  [[ -z "$ename" ]] && continue
  tf_import_add azurerm_kubernetes_cluster_extension "$(tf_name "${CLUSTER_NAME}_${ename}")" "$eid" \
    "Cluster extension $ename ($etype)"
done < <(jq -r '.[] | [.name, .id, (.extensionType // "")] | join("|")' <<<"$ext_json")

# --- Kubeconfig for everything that follows -----------------------------------
aks_credentials

hr
log 'Review notes for generated/aks_cluster.tf (the azurerm_kubernetes_cluster block is large):'
log '  * if "terraform validate" complains about read-only attributes, delete those lines'
log '  * when the cluster autoscaler is on, add  lifecycle { ignore_changes = [default_node_pool[0].node_count] }'
log "  * the default_node_pool block corresponds to pool '$default_pool'"
tf_import_end
