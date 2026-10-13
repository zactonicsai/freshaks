#!/usr/bin/env bash
# =============================================================================
#  discover/00-discover.sh — read-only inventory of the whole AKS environment
# =============================================================================
#  Changes NOTHING. Run it first so you know exactly what the import and the
#  destroy scripts are going to act on.
#
#  Output:
#     out/inventory.md     human-readable report (open it in any Markdown viewer)
#     out/inventory.json   the raw data behind the report
#
#  Azure CLI commands used:
#     az aks show              cluster properties (version, network plugin, identity, add-ons)
#     az aks nodepool list     every agent pool (mode, VM size, count, OS)
#     az resource list         every resource in the main RG and in the MC_ node RG
#     az aks get-credentials   (via aks_credentials) kubeconfig for the kubectl/helm calls
#  kubectl commands used:
#     kubectl get ns / pv / svc / ingress / deploy,sts,ds   -o json
#  helm commands used:
#     helm list -A -o json     every release in every namespace
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
require_tools kubectl helm
aks_credentials

INV_JSON="$OUT_DIR/inventory.json"
INV_MD="$OUT_DIR/inventory.md"
TMP="$OUT_DIR/.inventory-tmp"
mkdir -p "$TMP"

# ---------------------------------------------------------------------------
# 1. Azure side
# ---------------------------------------------------------------------------
log "Collecting Azure inventory ..."
az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -o json                         >"$TMP/cluster.json"
az aks nodepool list -g "$RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" -o json   >"$TMP/pools.json"
az resource list -g "$RESOURCE_GROUP" -o json                                       >"$TMP/rg.json"
if rg_exists "$NODE_RESOURCE_GROUP"; then
  az resource list -g "$NODE_RESOURCE_GROUP" -o json                                >"$TMP/node_rg.json"
else
  echo '[]'                                                                         >"$TMP/node_rg.json"
fi

# ---------------------------------------------------------------------------
# 2. Kubernetes side
# ---------------------------------------------------------------------------
log "Collecting Kubernetes inventory ..."
kubectl get ns -o json                                                              >"$TMP/namespaces.json"
helm list -A -o json                                                                >"$TMP/helm.json"
kubectl get pv -o json                                                              >"$TMP/pv.json"
kubectl get svc -A -o json | jq '[.items[] | select(.spec.type=="LoadBalancer")]'   >"$TMP/lb.json"
kubectl get ingress -A -o json                                                      >"$TMP/ingress.json"
kubectl get deploy,sts,ds -A -o json                                                >"$TMP/workloads.json"

# ---------------------------------------------------------------------------
# 3. Combine into one JSON document
# ---------------------------------------------------------------------------
jq -n \
  --slurpfile cluster   "$TMP/cluster.json" \
  --slurpfile pools     "$TMP/pools.json" \
  --slurpfile rg        "$TMP/rg.json" \
  --slurpfile node_rg   "$TMP/node_rg.json" \
  --slurpfile ns        "$TMP/namespaces.json" \
  --slurpfile helm      "$TMP/helm.json" \
  --slurpfile pv        "$TMP/pv.json" \
  --slurpfile lb        "$TMP/lb.json" \
  --slurpfile ingress   "$TMP/ingress.json" \
  --slurpfile workloads "$TMP/workloads.json" \
  '{
     generated_at: (now | todate),
     cluster: $cluster[0],
     node_pools: $pools[0],
     resources: { main_rg: $rg[0], node_rg: $node_rg[0] },
     kubernetes: {
       namespaces: [ $ns[0].items[].metadata.name ],
       helm_releases: $helm[0],
       persistent_volumes: [ $pv[0].items[] | {
           name: .metadata.name,
           claim: ((.spec.claimRef.namespace // "-") + "/" + (.spec.claimRef.name // "-")),
           driver: (.spec.csi.driver // (if .spec.azureDisk then "azureDisk(in-tree)" elif .spec.azureFile then "azureFile(in-tree)" else "other" end)),
           handle: (.spec.csi.volumeHandle // .spec.azureDisk.diskURI // ""),
           reclaim: .spec.persistentVolumeReclaimPolicy,
           phase: .status.phase } ],
       loadbalancer_services: [ $lb[0][] | { namespace: .metadata.namespace, name: .metadata.name, ip: (.status.loadBalancer.ingress[0].ip // "") } ],
       ingresses: [ $ingress[0].items[] | { namespace: .metadata.namespace, name: .metadata.name, class: (.spec.ingressClassName // "") } ],
       workloads: [ $workloads[0].items[] | { kind: .kind, namespace: .metadata.namespace, name: .metadata.name,
                     managed_by: (.metadata.labels["app.kubernetes.io/managed-by"] // "") } ]
     }
   }' >"$INV_JSON"

# ---------------------------------------------------------------------------
# 4. Render the Markdown report
# ---------------------------------------------------------------------------
{
  echo "# AKS inventory — \`$CLUSTER_NAME\`"
  echo
  echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) · subscription \`$SUBSCRIPTION_ID\`"
  echo
  echo "## Cluster"
  echo
  jq -r '"- Resource ID: `\(.id)`
- Location: \(.location)
- Kubernetes version: \(.kubernetesVersion)
- SKU tier: \(.sku.tier // "n/a")
- Node resource group: `\(.nodeResourceGroup)`
- Network plugin / policy: \(.networkProfile.networkPlugin) / \(.networkProfile.networkPolicy // "none")
- Outbound type: \(.networkProfile.outboundType // "loadBalancer")
- Private cluster: \(.apiServerAccessProfile.enablePrivateCluster // false)
- Identity type: \(.identity.type // "ServicePrincipal")
- Kubelet identity: `\(.identityProfile.kubeletidentity.resourceId // "n/a")`
- Log Analytics workspace (Container Insights): `\(.addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID // "not enabled")`
- Power state: \(.powerState.code // "n/a")"' "$TMP/cluster.json"
  echo
  echo "## Node pools"
  echo
  echo "| Pool | Mode | VM size | Count | Autoscale | OS | K8s version |"
  echo "|---|---|---|---|---|---|---|"
  jq -r '.[] | "| \(.name) | \(.mode) | \(.vmSize) | \(.count) | \(if .enableAutoScaling then "\(.minCount)-\(.maxCount)" else "off" end) | \(.osType)/\(.osSku // "") | \(.orchestratorVersion) |"' "$TMP/pools.json"
  echo
  echo "## Azure resources in \`$RESOURCE_GROUP\` (by type)"
  echo
  echo "| Resource type | Count | Names |"
  echo "|---|---|---|"
  jq -r 'group_by(.type) | .[] | "| \(.[0].type) | \(length) | \([.[].name] | join(", ")) |"' "$TMP/rg.json"
  echo
  if [[ -n "$NODE_RESOURCE_GROUP" ]]; then
    echo "## Azure resources in node resource group \`$NODE_RESOURCE_GROUP\` (managed by AKS)"
    echo
    echo "| Resource type | Count | Names |"
    echo "|---|---|---|"
    jq -r 'group_by(.type) | .[] | "| \(.[0].type) | \(length) | \([.[].name] | join(", ")) |"' "$TMP/node_rg.json"
    echo
  fi
  echo "## Kubernetes namespaces"
  echo
  jq -r --arg sys "$SYSTEM_NAMESPACES" '.items[].metadata.name as $n | "- \($n)\(if (($sys | split(" ")) | index($n)) != null then " _(system — skipped by the scripts)_" else "" end)"' "$TMP/namespaces.json"
  echo
  echo "## Helm releases"
  echo
  echo "| Namespace | Release | Chart | App version | Status |"
  echo "|---|---|---|---|---|"
  jq -r '.[] | "| \(.namespace) | \(.name) | \(.chart) | \(.app_version) | \(.status) |"' "$TMP/helm.json"
  echo
  echo "## Persistent volumes (Azure disks / files behind PVCs)"
  echo
  echo "| PV | Claim | Driver | Azure handle | Reclaim | Phase |"
  echo "|---|---|---|---|---|---|"
  jq -r '.kubernetes.persistent_volumes[] | "| \(.name) | \(.claim) | \(.driver) | `\(.handle)` | \(.reclaim) | \(.phase) |"' "$INV_JSON"
  echo
  echo "## LoadBalancer services (each one owns Azure LB rules + a public IP)"
  echo
  echo "| Namespace | Service | External IP |"
  echo "|---|---|---|"
  jq -r '.kubernetes.loadbalancer_services[] | "| \(.namespace) | \(.name) | \(.ip) |"' "$INV_JSON"
  echo
  echo "## Ingresses"
  echo
  echo "| Namespace | Ingress | Class |"
  echo "|---|---|---|"
  jq -r '.kubernetes.ingresses[] | "| \(.namespace) | \(.name) | \(.class) |"' "$INV_JSON"
  echo
  echo "## Workloads (Deployments / StatefulSets / DaemonSets)"
  echo
  echo "| Kind | Namespace | Name | Managed by |"
  echo "|---|---|---|---|"
  jq -r '.kubernetes.workloads[] | "| \(.kind) | \(.namespace) | \(.name) | \(.managed_by) |"' "$INV_JSON"
} >"$INV_MD"

rm -rf "$TMP"
hr
log "Inventory written:"
ok "${INV_MD#$ROOT_DIR/}"
ok "${INV_JSON#$ROOT_DIR/}"
