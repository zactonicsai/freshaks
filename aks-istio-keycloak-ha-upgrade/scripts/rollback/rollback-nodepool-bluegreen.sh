#!/usr/bin/env bash
# =============================================================================
# rollback-nodepool-bluegreen.sh — undo 23-aks-bluegreen-shift-workloads.sh:
# move the pods from the new node pool back to the old one.
# Works as long as the old pool was not deleted (step 24).
# Note: the control plane itself cannot go back; this only returns the
# workloads to nodes that run the previous kubelet version.
# Usage: ./scripts/rollback/rollback-nodepool-bluegreen.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster
# Both pool names must be known.
require_state BLUEGREEN_OLD_POOL "scripts/upgrade/22-aks-bluegreen-create-pool.sh"
# The new pool.
require_state BLUEGREEN_NEW_POOL "scripts/upgrade/22-aks-bluegreen-create-pool.sh"

# Ask before changing anything.
confirm "Move all pods from pool ${BLUEGREEN_NEW_POOL} back to pool ${BLUEGREEN_OLD_POOL}?" || fail "stopped by user"

# Announce the step.
step "Allow pods on the old pool ${BLUEGREEN_OLD_POOL} again"
# Uncordon = the scheduler may place pods on these nodes again.
run kubectl uncordon --selector "agentpool=${BLUEGREEN_OLD_POOL}"

# Announce the step.
step "Cordon every node of the new pool ${BLUEGREEN_NEW_POOL}"
# No new pods on the new nodes.
run kubectl cordon --selector "agentpool=${BLUEGREEN_NEW_POOL}"

# Drain the new nodes one by one.
for node in $(kubectl get nodes --selector "agentpool=${BLUEGREEN_NEW_POOL}" --output name); do
  # Announce the step.
  step "Drain ${node}"
  # Evicts the pods politely, respecting every PodDisruptionBudget.
  run kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --timeout="${DRAIN_TIMEOUT_MINUTES}m"
done

# The old pool is the active one again.
state_set ACTIVE_USER_POOL "${BLUEGREEN_OLD_POOL}"

# Announce the step.
step "Check the services"
# Same smoke test as after the install.
bash "${ROOT_DIR}/scripts/install/24-smoke-test.sh"
# Explain the state.
info "pool ${BLUEGREEN_NEW_POOL} is empty and cordoned. Delete it with: az aks nodepool delete --resource-group ${RESOURCE_GROUP} --cluster-name ${AKS_NAME} --name ${BLUEGREEN_NEW_POOL}  (or uncordon it and try the shift again)"
