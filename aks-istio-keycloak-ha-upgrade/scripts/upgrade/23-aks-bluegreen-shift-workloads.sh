#!/usr/bin/env bash
# =============================================================================
# 23-aks-bluegreen-shift-workloads.sh — blue/green, part 2: move all pods from
# the old pool to the new pool.
# First ALL old nodes are cordoned (no new pods land there), then they are
# drained one at a time. "drain" evicts pods politely: it respects every
# PodDisruptionBudget, so a service never loses all its pods at once.
# Usage: ./scripts/upgrade/23-aks-bluegreen-shift-workloads.sh
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

# Announce the step.
step "Cordon every node of the old pool ${BLUEGREEN_OLD_POOL}"
# AKS labels each node with agentpool=<pool name>. Cordon = "no new pods here".
# Cordoning all nodes first stops evicted pods from landing on another old node.
run kubectl cordon --selector "agentpool=${BLUEGREEN_OLD_POOL}"

# Drain the old nodes one by one.
for node in $(kubectl get nodes --selector "agentpool=${BLUEGREEN_OLD_POOL}" --output name); do
  # Announce the step.
  step "Drain ${node}"
  #   --ignore-daemonsets      DaemonSet pods belong to the node and stay
  #   --delete-emptydir-data   pods with scratch space (emptyDir) may be evicted
  #   --timeout                give up when a budget blocks the drain for too long
  run kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --timeout="${DRAIN_TIMEOUT_MINUTES}m"
done

# The new pool is now the one that runs the workloads.
state_set ACTIVE_USER_POOL "${BLUEGREEN_NEW_POOL}"

# Announce the step.
step "Show where the pods run now"
# The NODE column must show only nodes of the new pool (and the system pool).
run kubectl get pods --all-namespaces --output wide --field-selector metadata.namespace!=kube-system

# Announce the step.
step "Check the services"
# Same smoke test as after the install.
bash "${ROOT_DIR}/scripts/install/24-smoke-test.sh"
# Explain the state.
info "the old pool ${BLUEGREEN_OLD_POOL} is empty but still there. Way back: scripts/rollback/rollback-nodepool-bluegreen.sh. When you are sure: 24-aks-bluegreen-delete-old-pool.sh"
