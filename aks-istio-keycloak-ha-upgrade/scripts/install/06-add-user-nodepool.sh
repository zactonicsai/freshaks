#!/usr/bin/env bash
# =============================================================================
# 06-add-user-nodepool.sh — add the "user" node pool that runs Istio, the NFS
# server, PostgreSQL, Keycloak and the two applications.
# Separate pools let you upgrade (or replace) the workload nodes without
# touching the nodes that run the cluster's own system pods.
# Usage: ./scripts/install/06-add-user-nodepool.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Nothing to do when the pool already exists.
if az aks nodepool show --resource-group "${RESOURCE_GROUP}" --cluster-name "${AKS_NAME}" --name "${USER_POOL_NAME}" --output none 2>/dev/null; then
  # Tell the user and stop successfully.
  ok "node pool ${USER_POOL_NAME} already exists - nothing to do"
  # Leave the script with "success".
  exit 0
fi

# Announce the step.
step "Find the Kubernetes version of the control plane"
# A node pool may not be newer than the control plane, so use the same version.
cluster_version="$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --query currentKubernetesVersion --output tsv)"
# Show it.
info "control plane runs Kubernetes ${cluster_version}"

# Announce the step.
step "Add user node pool ${USER_POOL_NAME} (${USER_NODE_COUNT} x ${USER_NODE_SIZE})"
#   --mode User            ordinary workloads (system pods prefer the system pool)
#   --zones                one node per availability zone
#   --max-surge            extra nodes during upgrades, so capacity never drops
#   --drain-timeout        minutes to wait for pods to leave a node
#   --node-soak-duration   minutes to pause after each upgraded node
# ZONES is left unquoted on purpose so "1 2 3" becomes three arguments.
# shellcheck disable=SC2086
run az aks nodepool add \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster-name "${AKS_NAME}" \
  --name "${USER_POOL_NAME}" \
  --mode User \
  --kubernetes-version "${cluster_version}" \
  --node-count "${USER_NODE_COUNT}" \
  --node-vm-size "${USER_NODE_SIZE}" \
  --zones ${ZONES} \
  --max-surge "${MAX_SURGE}" \
  --drain-timeout "${DRAIN_TIMEOUT_MINUTES}" \
  --node-soak-duration "${NODE_SOAK_MINUTES}" \
  --output table

# Remember which user pool is the active one (the blue/green scripts change it).
state_set ACTIVE_USER_POOL "${USER_POOL_NAME}"
