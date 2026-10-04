#!/usr/bin/env bash
# =============================================================================
# 12-install-istiod.sh — install the Istio control plane "istiod" (OLD version)
# as a named revision, with two replicas for high availability.
# Usage: ./scripts/install/12-install-istiod.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster

# Revision name of the old version, e.g. 1-28-1.
rev="$(istio_rev "${ISTIO_VERSION_OLD}")"

# Announce the step.
step "Install istiod ${ISTIO_VERSION_OLD} as revision ${rev}"
# Helm release "istiod-<rev>" in namespace istio-system.
deploy_istiod "${ISTIO_VERSION_OLD}"

# Remember which Istio version is the active one.
state_set ISTIO_ACTIVE_VERSION "${ISTIO_VERSION_OLD}"

# Announce the step.
step "Show the control plane pods"
# Two pods, ideally in two different zones.
run kubectl --namespace istio-system get pods --selector app=istiod --output wide
# The PodDisruptionBudget keeps one of them running during node drains.
run kubectl --namespace istio-system get poddisruptionbudget
