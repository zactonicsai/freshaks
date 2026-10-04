#!/usr/bin/env bash
# =============================================================================
# 22-aks-bluegreen-create-pool.sh — blue/green alternative to step 21 for the
# user pool, part 1: create a NEW pool ("green") with the control plane's
# version next to the current pool ("blue"). Nothing moves yet.
# Why: the old nodes stay untouched until you delete them, so the way back is
# simply "move the pods back" (scripts/rollback/rollback-nodepool-bluegreen.sh).
# Cost: the pool exists twice for a while; you need the vCPU quota for that.
# Usage: ./scripts/upgrade/22-aks-bluegreen-create-pool.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster

# The pool that runs the workloads now ("blue").
old_pool="${ACTIVE_USER_POOL:-${USER_POOL_NAME}}"
# Name of the new pool: toggle a trailing "b" (apps -> appsb -> apps -> ...).
if [[ "${old_pool}" == *b ]]; then new_pool="${old_pool%b}"; else new_pool="${old_pool}b"; fi

# Announce the step.
step "Read the control plane version"
# The new pool gets exactly this version.
target="$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --query currentKubernetesVersion --output tsv)"
# Show the plan.
info "blue pool: ${old_pool}   green pool: ${new_pool}   Kubernetes: ${target}"

# Create the pool only when it does not exist yet.
if az aks nodepool show --resource-group "${RESOURCE_GROUP}" --cluster-name "${AKS_NAME}" --name "${new_pool}" --output none 2>/dev/null; then
  # Already there (the script was run before).
  ok "node pool ${new_pool} already exists"
else
  # Announce the step.
  step "Create node pool ${new_pool} with Kubernetes ${target}"
  # Same size, zones and upgrade settings as the pool it will replace.
  # ZONES is left unquoted on purpose so "1 2 3" becomes three arguments.
  # shellcheck disable=SC2086
  run az aks nodepool add --resource-group "${RESOURCE_GROUP}" --cluster-name "${AKS_NAME}" --name "${new_pool}" --mode User --kubernetes-version "${target}" --node-count "${USER_NODE_COUNT}" --node-vm-size "${USER_NODE_SIZE}" --zones ${ZONES} --max-surge "${MAX_SURGE}" --drain-timeout "${DRAIN_TIMEOUT_MINUTES}" --node-soak-duration "${NODE_SOAK_MINUTES}" --output table
fi

# Remember both names for steps 23 and 24 and for the rollback.
state_set BLUEGREEN_OLD_POOL "${old_pool}"
# The new pool.
state_set BLUEGREEN_NEW_POOL "${new_pool}"

# Announce the step.
step "Show both pools"
# Old and new nodes side by side.
run kubectl get nodes --label-columns topology.kubernetes.io/zone,agentpool
