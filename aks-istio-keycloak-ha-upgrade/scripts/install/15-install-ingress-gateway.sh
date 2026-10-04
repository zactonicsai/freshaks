#!/usr/bin/env bash
# =============================================================================
# 15-install-ingress-gateway.sh — install the Istio ingress gateway: two or
# more Envoy pods behind an Azure load balancer with our static public IP.
# Usage: ./scripts/install/15-install-ingress-gateway.sh
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
step "Install the ingress gateway (chart ${ISTIO_ACTIVE_VERSION})"
# Helm waits until the pods are ready AND Azure has attached the public IP.
deploy_ingress_gateway "${ISTIO_ACTIVE_VERSION}"

# Announce the step.
step "Check that the load balancer uses our static IP ${PUBLIC_IP}"
# Read the external IP that Kubernetes reports for the Service.
external_ip="$(kubectl --namespace istio-ingress get service istio-ingressgateway --output jsonpath='{.status.loadBalancer.ingress[0].ip}')"
# It must be the address created in step 04.
[[ "${external_ip}" == "${PUBLIC_IP}" ]] || fail "The gateway got IP '${external_ip}' instead of ${PUBLIC_IP}. Check scripts/install/07-grant-network-role.sh and 'kubectl -n istio-ingress describe service istio-ingressgateway'."
# Report success.
ok "ingress gateway is reachable at ${PUBLIC_IP}"

# Announce the step.
step "Show the gateway pods, the autoscaler and the disruption budget"
# Two pods, ideally in two different zones.
run kubectl --namespace istio-ingress get pods --output wide
# HorizontalPodAutoscaler (min 2) and PodDisruptionBudget (min 1 available).
run kubectl --namespace istio-ingress get horizontalpodautoscaler,poddisruptionbudget
