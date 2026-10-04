#!/usr/bin/env bash
# =============================================================================
# 24-aks-bluegreen-delete-old-pool.sh — blue/green, part 3: delete the old,
# now empty node pool. After this step the easy way back is gone.
# Usage: ./scripts/upgrade/24-aks-bluegreen-delete-old-pool.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# The old pool must be known.
require_state BLUEGREEN_OLD_POOL "scripts/upgrade/22-aks-bluegreen-create-pool.sh"
# Never delete the pool that is currently active.
[[ "${BLUEGREEN_OLD_POOL}" != "${ACTIVE_USER_POOL:-}" ]] || fail "Pool ${BLUEGREEN_OLD_POOL} is still the active pool. Run 23-aks-bluegreen-shift-workloads.sh first."

# Ask before deleting.
confirm "Delete the old node pool ${BLUEGREEN_OLD_POOL}?" || fail "stopped by user"

# Announce the step.
step "Delete node pool ${BLUEGREEN_OLD_POOL}"
# Removes the virtual machines of the pool; the command returns when they are gone.
run az aks nodepool delete --resource-group "${RESOURCE_GROUP}" --cluster-name "${AKS_NAME}" --name "${BLUEGREEN_OLD_POOL}"

# The blue/green round is finished: forget both names.
state_set BLUEGREEN_OLD_POOL ""
# The new pool is simply "the user pool" from now on.
state_set BLUEGREEN_NEW_POOL ""

# Announce the step.
step "Show the remaining node pools"
# Name, mode, version and node count of each pool.
run az aks nodepool list --resource-group "${RESOURCE_GROUP}" --cluster-name "${AKS_NAME}" --query "[].{name:name, mode:mode, version:currentOrchestratorVersion, nodes:count}" --output table
