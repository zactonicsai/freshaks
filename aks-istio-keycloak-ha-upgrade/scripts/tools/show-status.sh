#!/usr/bin/env bash
# =============================================================================
# show-status.sh — one-page overview of the cluster: versions, nodes, Helm
# releases, pods, sidecar versions, disruption budgets and volumes.
# It changes nothing; run it before, during and after an upgrade.
# Usage: ./scripts/tools/show-status.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster

# Announce the step.
step "Versions remembered by the scripts"
# The state file is plain KEY='value' text.
run cat "${STATE_FILE}"

# Announce the step.
step "Nodes: Kubernetes version, zone and node pool"
# VERSION is the kubelet version of each node.
run kubectl get nodes --label-columns topology.kubernetes.io/zone,agentpool

# Announce the step.
step "Helm releases in all namespaces"
# CHART and APP VERSION show what is installed; STATUS should be "deployed".
run helm list --all-namespaces

# Announce the step.
step "Pods of the example"
# One block per namespace; -o wide shows the node of each pod.
for namespace in istio-system istio-ingress istio-egress nfs-storage postgres keycloak apps; do
  # List the pods of this namespace.
  run kubectl --namespace "${namespace}" get pods --output wide
done

# Announce the step.
step "Istio proxy version of every pod in the mesh"
# Columns: namespace, pod, proxy image. After an upgrade all tags must match.
mesh_proxy_report

# Announce the step.
step "Revision tags"
# REV shows which control plane each injection webhook belongs to.
run kubectl get mutatingwebhookconfigurations --label-columns istio.io/rev,istio.io/tag

# Announce the step.
step "PodDisruptionBudgets"
# ALLOWED DISRUPTIONS must be 1 or more, otherwise node drains will hang.
run kubectl get poddisruptionbudgets --all-namespaces

# Announce the step.
step "Volumes"
# All claims with their size, access mode and StorageClass.
run kubectl get persistentvolumeclaims --all-namespaces
