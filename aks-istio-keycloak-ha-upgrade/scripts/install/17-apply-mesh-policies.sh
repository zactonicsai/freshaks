#!/usr/bin/env bash
# =============================================================================
# 17-apply-mesh-policies.sh — apply the security rules of the mesh with kubectl:
# strict mutual TLS, who-may-call-whom, and the one allowed way to the internet.
# Usage: ./scripts/install/17-apply-mesh-policies.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster

# Announce the step.
step "Require mutual TLS between all pods of the mesh"
# One PeerAuthentication in istio-system applies to the whole mesh.
kapply "${ROOT_DIR}/k8s/istio/peer-authentication.yaml"

# Announce the step.
step "Allow only the needed connections (AuthorizationPolicy)"
# gateway -> apps, gateway and apps -> Keycloak, Keycloak -> PostgreSQL.
kapply "${ROOT_DIR}/k8s/istio/authorization-policies.yaml"

# Announce the step.
step "Allow ${EGRESS_TEST_HOST} through the egress gateway"
# ServiceEntry + Gateway + DestinationRule + VirtualService for one host.
kapply "${ROOT_DIR}/k8s/istio/egress.yaml"

# Announce the step.
step "Show the policies"
# Lists the mTLS and authorization rules in all namespaces.
run kubectl get peerauthentications,authorizationpolicies --all-namespaces
# Lists the objects that describe the egress path.
run kubectl --namespace istio-egress get serviceentries,gateways,destinationrules,virtualservices
