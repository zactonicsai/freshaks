#!/usr/bin/env bash
# =============================================================================
# 21-aks-upgrade-nodepool.sh — upgrade node pools to the control plane's
# version, in place, node by node ("surge" upgrade).
# For every node AKS: adds a new node with the new version (surge), cordons
# and drains an old node (respecting PodDisruptionBudgets), waits the soak
# time, deletes the old node, and continues with the next one.
# Usage: ./scripts/upgrade/21-aks-upgrade-nodepool.sh [POOL ...]
#        Without arguments: all pools, system pools first.
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster

# Announce the step.
step "Read the control plane version"
# Node pools are upgraded to exactly this version.
target="$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --query currentKubernetesVersion --output tsv)"
# Show it.
info "control plane: ${target}"

# Pools to upgrade: the arguments, or all pools sorted by mode
# ("System" sorts before "User", so the system pool goes first).
pools="${*:-$(az aks nodepool list --resource-group "${RESOURCE_GROUP}" --cluster-name "${AKS_NAME}" --query "sort_by(@, &mode)[].name" --output tsv | tr '\n' ' ')}"

# One pool after the other (split at the spaces on purpose).
for pool in ${pools}; do
  # Version the pool runs now.
  pool_version="$(az aks nodepool show --resource-group "${RESOURCE_GROUP}" --cluster-name "${AKS_NAME}" --name "${pool}" --query currentOrchestratorVersion --output tsv)"
  # Already there: skip.
  if [[ "${pool_version}" == "${target}" ]]; then ok "node pool ${pool} already runs ${target}"; continue; fi

  # Announce the step.
  step "Upgrade node pool ${pool}: ${pool_version} -> ${target}"
  #   --max-surge            extra nodes added first, so capacity never drops
  #   --drain-timeout        minutes to wait for pods to leave a node
  #   --node-soak-duration   minutes to pause after each node
  # If a PodDisruptionBudget blocks a drain for longer than the timeout the
  # upgrade stops with an error; fix the cause and run this script again.
  run az aks nodepool upgrade --resource-group "${RESOURCE_GROUP}" --cluster-name "${AKS_NAME}" --name "${pool}" --kubernetes-version "${target}" --max-surge "${MAX_SURGE}" --drain-timeout "${DRAIN_TIMEOUT_MINUTES}" --node-soak-duration "${NODE_SOAK_MINUTES}" --yes --output table

  # Announce the step.
  step "Show the nodes after upgrading ${pool}"
  # VERSION shows the kubelet version of each node.
  run kubectl get nodes --label-columns topology.kubernetes.io/zone,agentpool
done
