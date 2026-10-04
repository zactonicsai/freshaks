#!/usr/bin/env bash
# =============================================================================
# 08-get-credentials.sh — download the kubeconfig of the cluster into the
# project folder (.state/kubeconfig).
# All scripts use only this file, so they can never touch another cluster that
# your normal ~/.kube/config points at.
# Usage: ./scripts/install/08-get-credentials.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Announce the step.
step "Download the kubeconfig to ${KUBECONFIG}"
# --file writes to our private file; --overwrite-existing replaces an old entry.
run az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --file "${KUBECONFIG}" --overwrite-existing
# Only the current user may read the file (it is a login for the cluster).
chmod 600 "${KUBECONFIG}"

# Announce the step.
step "Check the connection and list the nodes"
# Shows every node with its Kubernetes version.
run kubectl get nodes --output wide
# Shows which availability zone and node pool each node belongs to.
run kubectl get nodes --label-columns topology.kubernetes.io/zone,agentpool
# Tell the user how to use the same file by hand.
info "to use kubectl yourself:  export KUBECONFIG=${KUBECONFIG}"
