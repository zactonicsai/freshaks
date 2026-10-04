#!/usr/bin/env bash
# =============================================================================
# 23-apply-routing.sh — tell the ingress gateway what to listen on and where
# to send the traffic, with kubectl.
# Usage: ./scripts/install/23-apply-routing.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The host names must be known.
require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"

# Announce the step.
step "Open ports 80 and 443 on the ingress gateway (Gateway)"
# Port 80 redirects to HTTPS; port 443 ends TLS with the wildcard certificate.
kapply "${ROOT_DIR}/k8s/istio/gateway.yaml"

# Announce the step.
step "Route the three host names to their Services (VirtualService)"
# app1.<domain>, app2.<domain> and keycloak.<domain>.
kapply "${ROOT_DIR}/k8s/istio/virtualservices.yaml"

# Announce the step.
step "Sticky sessions and outlier detection (DestinationRule)"
# Keeps a browser on the same pod and takes broken pods out of rotation.
kapply "${ROOT_DIR}/k8s/istio/destinationrules.yaml"

# Announce the step.
step "Show the routing objects"
# Lists Gateway, VirtualServices and DestinationRules in all namespaces.
run kubectl get gateways.networking.istio.io,virtualservices.networking.istio.io,destinationrules.networking.istio.io --all-namespaces
