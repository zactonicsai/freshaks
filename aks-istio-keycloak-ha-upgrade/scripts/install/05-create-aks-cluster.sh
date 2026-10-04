#!/usr/bin/env bash
# =============================================================================
# 05-create-aks-cluster.sh — create the AKS cluster with the OLD Kubernetes
# version and a system node pool spread over three availability zones.
# Takes about 5 to 10 minutes.
# Usage: ./scripts/install/05-create-aks-cluster.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# The registry must exist, because the cluster gets pull rights on it.
require_state ACR_NAME "scripts/install/03-create-acr.sh"

# Nothing to do when the cluster already exists (az aks create would try to
# change it, which is not what an install script should do).
if az aks show --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --output none 2>/dev/null; then
  # Tell the user and stop successfully.
  ok "cluster ${AKS_NAME} already exists - nothing to do"
  # Leave the script with "success".
  exit 0
fi

# Announce the step.
step "Create AKS cluster ${AKS_NAME} with Kubernetes ${K8S_VERSION_OLD}"
# The options, one by one:
#   --kubernetes-version      old minor version; AKS picks its newest patch
#   --tier standard           control plane with financially backed uptime SLA
#   --nodepool-name           name of the first (system) node pool
#   --node-count / --zones    three nodes, one per availability zone
#   --nodepool-taints         keep ordinary workloads off the system nodes
#   --network-plugin azure + --network-plugin-mode overlay
#                             Azure CNI Overlay: pods get private IPs from
#                             --pod-cidr, so the VNet does not run out of addresses
#   --load-balancer-sku standard  zone-redundant Azure load balancer
#   --enable-managed-identity no passwords or service-principal secrets to rotate
#   --attach-acr              let the nodes pull images from our registry
#   --auto-upgrade-channel none + --node-os-upgrade-channel None
#                             nothing upgrades by itself: in this example every
#                             upgrade is a deliberate, logged step (in production
#                             use a channel together with a maintenance window)
#   --no-ssh-key              no SSH key on the nodes (not needed)
# ZONES is left unquoted on purpose so "1 2 3" becomes three arguments.
# shellcheck disable=SC2086
run az aks create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${AKS_NAME}" \
  --location "${LOCATION}" \
  --kubernetes-version "${K8S_VERSION_OLD}" \
  --tier "${AKS_TIER}" \
  --nodepool-name "${SYSTEM_POOL_NAME}" \
  --node-count "${SYSTEM_NODE_COUNT}" \
  --node-vm-size "${SYSTEM_NODE_SIZE}" \
  --zones ${ZONES} \
  --nodepool-taints CriticalAddonsOnly=true:NoSchedule \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --pod-cidr "${POD_CIDR}" \
  --load-balancer-sku standard \
  --enable-managed-identity \
  --attach-acr "${ACR_NAME}" \
  --auto-upgrade-channel none \
  --node-os-upgrade-channel None \
  --no-ssh-key \
  --tags purpose=aks-ha-upgrade-example \
  --output table

# Announce the step.
step "Set the upgrade behaviour of the system node pool"
# --max-surge: how many extra nodes AKS adds during an upgrade, so capacity
# never drops. --drain-timeout: minutes to wait for pods to leave a node.
# --node-soak-duration: minutes to pause after each node.
run az aks nodepool update --resource-group "${RESOURCE_GROUP}" --cluster-name "${AKS_NAME}" --name "${SYSTEM_POOL_NAME}" --max-surge "${MAX_SURGE}" --drain-timeout "${DRAIN_TIMEOUT_MINUTES}" --node-soak-duration "${NODE_SOAK_MINUTES}" --output table

# Announce the step.
step "Show the exact Kubernetes version that was installed"
# The control plane version including the patch number, e.g. 1.34.2
run az aks show --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --query "{kubernetes:currentKubernetesVersion, tier:sku.tier, state:provisioningState}" --output table
