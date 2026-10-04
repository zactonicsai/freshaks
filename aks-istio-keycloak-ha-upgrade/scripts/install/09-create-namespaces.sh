#!/usr/bin/env bash
# =============================================================================
# 09-create-namespaces.sh — create all namespaces with kubectl.
# The namespaces for PostgreSQL, Keycloak and the apps carry the label
# istio.io/rev=<tag>, which switches on sidecar injection for them.
# Usage: ./scripts/install/09-create-namespaces.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster

# Announce the step.
step "Create the namespaces"
# kapply fills in the placeholders of the manifest and runs "kubectl apply".
kapply "${ROOT_DIR}/k8s/namespaces.yaml"

# Announce the step.
step "Show the namespaces and their Istio label"
# The column shows which namespaces get sidecars.
run kubectl get namespaces --label-columns istio.io/rev
