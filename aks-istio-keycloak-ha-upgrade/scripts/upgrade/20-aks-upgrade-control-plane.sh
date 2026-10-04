#!/usr/bin/env bash
# =============================================================================
# 20-aks-upgrade-control-plane.sh — upgrade the Kubernetes control plane (API
# server, scheduler, ...) by ONE minor version. The nodes are not touched, so
# running pods keep running; with the Standard tier the API server itself
# stays reachable during the upgrade.
# IMPORTANT: a control plane upgrade cannot be undone. AKS has no downgrade.
# Usage: ./scripts/upgrade/20-aks-upgrade-control-plane.sh [MINOR]
#        Default: the next entry of K8S_UPGRADE_PATH, for example 1.35
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The running Istio version must be known for the compatibility check.
require_state ISTIO_ACTIVE_VERSION "scripts/install/12-install-istiod.sh"

# Announce the step.
step "Read the current versions from Azure"
# Full version of the control plane, e.g. 1.34.2
current="$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --query currentKubernetesVersion --output tsv)"
# Its minor version, e.g. 1.34
current_minor="$(minor_of "${current}")"
# Show it.
info "control plane: ${current}"

# Target minor: first argument, or the next minor on the upgrade path.
target_minor="${1:-$(next_version "${current_minor}" "${K8S_UPGRADE_PATH}")}"
# Nothing newer on the path: there is nothing to do.
if [[ -z "${target_minor}" ]]; then ok "Kubernetes ${current} is already the newest version on the upgrade path"; exit 0; fi

# Announce the step.
step "Check the size of the hop: ${current_minor} -> ${target_minor}"
# Kubernetes (and AKS) only allow upgrades to the NEXT minor version.
if (( ${target_minor#*.} - ${current_minor#*.} > 1 )); then fail "Kubernetes must be upgraded one minor version at a time. ${current_minor} -> ${target_minor} skips a version."; fi
# Going backwards is impossible.
if (( ${target_minor#*.} < ${current_minor#*.} )); then fail "AKS cannot downgrade the control plane (${current_minor} -> ${target_minor})."; fi
# Report success.
ok "hop size is fine"

# Announce the step.
step "Check that every node pool has caught up with the control plane"
# Finish one hop completely before starting the next: nodes that fall too far
# behind the control plane are not supported.
for pool_version in $(az aks nodepool list --resource-group "${RESOURCE_GROUP}" --cluster-name "${AKS_NAME}" --query "[].currentOrchestratorVersion" --output tsv); do
  # Compare minors only; patch versions may differ.
  if [[ "$(minor_of "${pool_version}")" != "${current_minor}" ]]; then fail "A node pool still runs ${pool_version}. Run 21-aks-upgrade-nodepool.sh first."; fi
done
# Report success.
ok "all node pools run ${current_minor}"

# Announce the step.
step "Check that Istio ${ISTIO_ACTIVE_VERSION} supports Kubernetes ${target_minor}"
# Upgrading Kubernetes past what the installed Istio supports is the classic
# way to break a mesh; this is why Istio was upgraded first.
check_istio_k8s "${ISTIO_ACTIVE_VERSION}" "${target_minor}"

# Announce the step.
step "Find the newest ${target_minor} patch version that AKS offers"
# Lists every version this cluster may upgrade to; keep the target minor and
# take the highest patch. "|| true": no match is handled on the next line.
target="$(az aks get-upgrades --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --query "controlPlaneProfile.upgrades[].kubernetesVersion" --output tsv | grep "^${target_minor}\." | sort -V | tail -n 1 || true)"
# AKS may not offer the version in this region (yet, or any more).
[[ -n "${target}" ]] || fail "AKS offers no ${target_minor} upgrade for this cluster. Check: az aks get-upgrades --resource-group ${RESOURCE_GROUP} --name ${AKS_NAME} --output table"
# Show the choice.
info "target version: ${target}"

# Last chance to stop.
confirm "Upgrade the control plane ${current} -> ${target}? This cannot be undone." || fail "stopped by user"

# Announce the step.
step "Upgrade the control plane to ${target}"
# --control-plane-only leaves all node pools on their current version.
run az aks upgrade --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --kubernetes-version "${target}" --control-plane-only --yes --output table

# Announce the step.
step "Show the result"
# Client and server version; the server shows the new version.
run kubectl version
# The nodes still show the old version - that is expected.
run kubectl get nodes
