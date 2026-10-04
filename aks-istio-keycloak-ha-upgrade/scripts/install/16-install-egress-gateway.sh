#!/usr/bin/env bash
# =============================================================================
# 16-install-egress-gateway.sh — install the Istio egress gateway: the pods
# through which all allowed traffic leaves the mesh for the internet.
# Usage: ./scripts/install/16-install-egress-gateway.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The control plane must be installed first.
require_state ISTIO_ACTIVE_VERSION "scripts/install/12-install-istiod.sh"

# Announce the step.
step "Install the egress gateway (chart ${ISTIO_ACTIVE_VERSION})"
# Same chart as the ingress gateway, but with a cluster-internal Service.
deploy_egress_gateway "${ISTIO_ACTIVE_VERSION}"

# Announce the step.
step "Show the gateway pods, the autoscaler and the disruption budget"
# Two pods, ideally in two different zones.
run kubectl --namespace istio-egress get pods --output wide
# HorizontalPodAutoscaler (min 2) and PodDisruptionBudget (min 1 available).
run kubectl --namespace istio-egress get horizontalpodautoscaler,poddisruptionbudget
