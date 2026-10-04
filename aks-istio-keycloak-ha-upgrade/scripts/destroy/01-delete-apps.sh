#!/usr/bin/env bash
# =============================================================================
# 01-delete-apps.sh — remove the two applications from the cluster.
# Usage: ./scripts/destroy/01-delete-apps.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster
# Ask before deleting.
confirm "Remove app1 and app2 from the cluster?" || fail "stopped by user"

# Announce the step.
step "Uninstall Helm release app1"
# Removes Deployment, Service, ServiceAccount and PodDisruptionBudget.
helm_remove app1 apps

# Announce the step.
step "Uninstall Helm release app2"
# Same for the second application.
helm_remove app2 apps

# Announce the step.
step "Delete the OIDC client secrets"
# They were created with kubectl, so Helm does not know them.
run kubectl --namespace apps delete secret app1-oidc app2-oidc --ignore-not-found
