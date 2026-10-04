#!/usr/bin/env bash
# =============================================================================
# 25-aks-upgrade-all-hops.sh — walk Kubernetes from the installed version to
# the newest one, one minor version at a time. Every hop: control plane first,
# then the node pools, then a smoke test.
# NODEPOOL_STRATEGY (config/env.sh) selects how the user pool is replaced:
# "surge" (in place) or "bluegreen" (new pool, move pods, delete old pool).
# Usage: ./scripts/upgrade/25-aks-upgrade-all-hops.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster

# Ask once for the whole walk instead of once per hop.
confirm "Upgrade Kubernetes along the path '${K8S_UPGRADE_PATH}' (strategy for the user pool: ${NODEPOOL_STRATEGY})? Control plane upgrades cannot be undone." || fail "stopped by user"
# The scripts started below must not ask again.
export ASSUME_YES=true

# One round per minor version on the path (split at the spaces on purpose).
for minor in ${K8S_UPGRADE_PATH}; do
  # Minor version the control plane runs now.
  current_minor="$(minor_of "$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --query currentKubernetesVersion --output tsv)")"
  # Skip minors that are not newer than the running one.
  if [[ "$(next_version "${current_minor}" "${minor}")" != "${minor}" ]]; then info "skipping ${minor}: the control plane already runs ${current_minor}"; continue; fi
  # Control plane first.
  run_script upgrade/20-aks-upgrade-control-plane.sh "${minor}"
  # Then the nodes.
  if [[ "${NODEPOOL_STRATEGY}" == "bluegreen" ]]; then
    # The system pool is always upgraded in place.
    run_script upgrade/21-aks-upgrade-nodepool.sh "${SYSTEM_POOL_NAME}"
    # The user pool is replaced by a new pool.
    run_script upgrade/22-aks-bluegreen-create-pool.sh
    # Move the pods.
    run_script upgrade/23-aks-bluegreen-shift-workloads.sh
    # Delete the old pool.
    run_script upgrade/24-aks-bluegreen-delete-old-pool.sh
  else
    # All pools in place, system pool first.
    run_script upgrade/21-aks-upgrade-nodepool.sh
  fi
  # Check the services before the next hop.
  run_script install/24-smoke-test.sh
done

# Final message.
ok "Kubernetes upgrade path finished"
# Show the result.
run kubectl get nodes --label-columns topology.kubernetes.io/zone,agentpool
