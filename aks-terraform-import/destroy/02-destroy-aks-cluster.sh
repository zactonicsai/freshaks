#!/usr/bin/env bash
# =============================================================================
#  destroy/02-destroy-aks-cluster.sh — delete the managed cluster (az cli)
# =============================================================================
#  Deleting the cluster also deletes its NODE resource group (MC_*): the VM
#  scale sets, the "kubernetes" load balancer, outbound public IPs, the
#  agent-pool NSG and route table, the kubelet identity, and every PVC disk
#  that was still inside that group. Run 01-destroy-kubernetes-workloads.sh
#  first if you want Azure to release LB public IPs and Retain volumes cleanly.
#
#  Options (env vars)
#    DELETE_NODE_RG=false   if the node RG somehow survives, delete it too
#
#  Azure CLI commands used:
#     az aks show -g <rg> -n <cluster>                  does the cluster still exist?
#     az aks delete -g <rg> -n <cluster> --yes --no-wait   start deletion without a prompt, return immediately
#     az aks wait -g <rg> -n <cluster> --deleted         block until the cluster is gone (up to --timeout seconds)
#     az group exists -n <node rg>                       verify the node RG was removed
#     az group delete -n <node rg> --yes                 (opt-in) remove a leftover node RG
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
DELETE_NODE_RG="${DELETE_NODE_RG:-false}"

if ! az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -o none 2>/dev/null; then
  log "Cluster $CLUSTER_NAME not found in $RESOURCE_GROUP — nothing to delete."
  exit 0
fi

hr
warn "This DELETES the AKS cluster $CLUSTER_NAME and its node resource group ${NODE_RESOURCE_GROUP:-<unknown>}."
confirm "$CLUSTER_NAME"

log "az aks delete (async)"
run az aks delete -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --yes --no-wait

log "Waiting for deletion to finish (this usually takes 5-15 minutes) ..."
run az aks wait -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --deleted --timeout 3600 \
  || warn "az aks wait timed out or failed — check the portal / 'az aks show'"

if [[ -n "$NODE_RESOURCE_GROUP" ]] && rg_exists "$NODE_RESOURCE_GROUP"; then
  if [[ "$DELETE_NODE_RG" == "true" ]]; then
    warn "Node resource group $NODE_RESOURCE_GROUP still exists — deleting it (DELETE_NODE_RG=true)"
    run az group delete -n "$NODE_RESOURCE_GROUP" --yes --no-wait
    run az group wait -n "$NODE_RESOURCE_GROUP" --deleted --timeout 1800 || warn "node RG deletion did not finish in time"
  else
    warn "Node resource group $NODE_RESOURCE_GROUP still exists. It normally disappears a few minutes after the cluster; re-run with DELETE_NODE_RG=true to force."
  fi
fi

hr
ok "Cluster deleted. Next: ./destroy/03-destroy-disks.sh (or 06-destroy-resource-group.sh to remove everything else at once)"
