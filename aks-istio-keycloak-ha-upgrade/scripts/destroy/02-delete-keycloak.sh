#!/usr/bin/env bash
# =============================================================================
# 02-delete-keycloak.sh — remove Keycloak from the cluster.
# Its data (realm, users) lives in PostgreSQL and is not touched here.
# Usage: ./scripts/destroy/02-delete-keycloak.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster
# Ask before deleting.
confirm "Remove Keycloak from the cluster?" || fail "stopped by user"

# Announce the step.
step "Uninstall Helm release keycloak"
# Removes Deployment, Services, realm secret, ServiceAccount and budget.
helm_remove keycloak keycloak

# Announce the step.
step "Delete the Keycloak credentials secret"
# It was created with kubectl, so Helm does not know it.
run kubectl --namespace keycloak delete secret keycloak-credentials --ignore-not-found
