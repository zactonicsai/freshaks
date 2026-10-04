#!/usr/bin/env bash
# =============================================================================
# 06-delete-aks-cluster.sh — delete the AKS cluster with everything in it:
# nodes, pods, load balancer and all disks the cluster created.
# The resource group, the registry and the public IP stay (see step 07).
# Usage: ./scripts/destroy/06-delete-aks-cluster.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Nothing to do when the cluster does not exist.
if ! az aks show --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --output none 2>/dev/null; then
  # Tell the user and stop successfully.
  ok "cluster ${AKS_NAME} does not exist - nothing to do"
  # Leave the script with "success".
  exit 0
fi

# Ask before deleting.
confirm "DELETE the AKS cluster ${AKS_NAME} in ${RESOURCE_GROUP} with all its data?" || fail "stopped by user"

# Announce the step.
step "Delete AKS cluster ${AKS_NAME} (about 10 minutes)"
# --yes skips Azure's own question; the command returns when the cluster is gone.
run az aks delete --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --yes

# Announce the step.
step "Remove the kubeconfig of the deleted cluster"
# It points at a cluster that no longer exists.
rm -f "${KUBECONFIG}"
# Stop the availability probe if it is still running ("|| true": it may not be).
bash "${ROOT_DIR}/scripts/tools/availability-probe.sh" stop >/dev/null 2>&1 || true
