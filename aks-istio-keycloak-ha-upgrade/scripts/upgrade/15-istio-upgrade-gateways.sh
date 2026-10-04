#!/usr/bin/env bash
# =============================================================================
# 15-istio-upgrade-gateways.sh — upgrade the ingress and the egress gateway to
# the active Istio version: first the Helm charts, then (if still needed) a
# rolling restart so the pods pick up the new proxy.
# Each gateway has at least two pods, a PodDisruptionBudget and a rolling
# update that starts a new pod before it stops an old one.
# Usage: ./scripts/upgrade/15-istio-upgrade-gateways.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The active Istio version must be known.
require_state ISTIO_ACTIVE_VERSION "scripts/install/12-install-istiod.sh"

# Announce the step.
step "Upgrade the ingress gateway chart to ${ISTIO_ACTIVE_VERSION}"
# Same values as at install time; only the chart version changes.
deploy_ingress_gateway "${ISTIO_ACTIVE_VERSION}"

# Announce the step.
step "Upgrade the egress gateway chart to ${ISTIO_ACTIVE_VERSION}"
# Same values as at install time; only the chart version changes.
deploy_egress_gateway "${ISTIO_ACTIVE_VERSION}"

# Announce the step.
step "Restart the gateways if any pod still runs another proxy version"
# The chart upgrade usually replaces the pods already. awk looks for a gateway
# pod whose proxy image does not carry the active version; only then restart.
if mesh_proxy_report | awk -v wanted=":${ISTIO_ACTIVE_VERSION}" '($1 == "istio-ingress" || $1 == "istio-egress") && index($3, wanted) == 0 { found = 1 } END { exit found ? 0 : 1 }'; then
  # Rolling restart of both gateways.
  restart_gateways
else
  # Nothing to do.
  ok "all gateway pods already run proxy ${ISTIO_ACTIVE_VERSION}"
fi

# Announce the step.
step "Show the gateway pods"
# Ingress gateway pods.
run kubectl --namespace istio-ingress get pods --output wide
# Egress gateway pods.
run kubectl --namespace istio-egress get pods --output wide
