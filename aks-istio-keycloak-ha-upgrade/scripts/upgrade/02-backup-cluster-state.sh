#!/usr/bin/env bash
# =============================================================================
# 02-backup-cluster-state.sh — save a snapshot of "what is deployed and how"
# into .state/backups/cluster-<time>/ before an upgrade: Helm releases with
# their values and manifests, all Istio configuration and all workload objects.
# With these files you can see exactly what changed, and re-apply the old
# definitions if you have to. Kubernetes secrets are NOT exported.
# Usage: ./scripts/upgrade/02-backup-cluster-state.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster

# One folder per snapshot.
snapshot="${BACKUP_DIR}/cluster-$(date +%Y%m%d-%H%M%S)"
# Create it.
mkdir -p "${snapshot}"

# Announce the step.
step "Save the list of Helm releases"
# One line per release with chart version and status.
helm list --all-namespaces > "${snapshot}/helm-releases.txt"

# Announce the step.
step "Save the values and the rendered manifest of every Helm release"
# Walk through the namespaces of the example.
for namespace in istio-system istio-ingress istio-egress nfs-storage postgres keycloak apps; do
  # --short prints only the release names.
  for release in $(helm list --namespace "${namespace}" --short); do
    # All values the release was installed with (the Keycloak file contains
    # the client secrets, which is why .state is readable only by you).
    helm get values "${release}" --namespace "${namespace}" --all --output yaml > "${snapshot}/${namespace}--${release}--values.yaml"
    # The exact Kubernetes objects Helm created.
    helm get manifest "${release}" --namespace "${namespace}" > "${snapshot}/${namespace}--${release}--manifest.yaml"
    # Show progress.
    info "saved ${namespace}/${release}"
  done
done

# Announce the step.
step "Save the Istio configuration"
# Routing, egress and security objects of all namespaces in one file.
kubectl get gateways.networking.istio.io,virtualservices.networking.istio.io,destinationrules.networking.istio.io,serviceentries.networking.istio.io,peerauthentications.security.istio.io,authorizationpolicies.security.istio.io --all-namespaces --output yaml > "${snapshot}/istio-config.yaml"

# Announce the step.
step "Save workloads, services, budgets, autoscalers and volume claims"
# Everything that defines how the workloads run.
kubectl get deployments,statefulsets,services,poddisruptionbudgets,horizontalpodautoscalers,persistentvolumeclaims --all-namespaces --output yaml > "${snapshot}/workloads.yaml"
# Cluster-wide objects: namespaces, storage classes and volumes.
kubectl get namespaces,storageclasses,persistentvolumes --output yaml > "${snapshot}/cluster-objects.yaml"
# Nodes with their versions, for the record.
kubectl get nodes --output wide > "${snapshot}/nodes.txt"

# Remember the folder.
state_set LAST_CLUSTER_SNAPSHOT "${snapshot}"
# Show what was written.
run ls -l "${snapshot}"
