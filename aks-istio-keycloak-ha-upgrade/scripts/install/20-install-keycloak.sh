#!/usr/bin/env bash
# =============================================================================
# 20-install-keycloak.sh — install Keycloak (OLD version) with Helm: two pods
# that form one cluster. The first start creates the database tables and
# imports the realm "demo" with both OIDC clients and the test users.
# Usage: ./scripts/install/20-install-keycloak.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The database must be installed first.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/19-install-postgres.sh"

# Announce the step.
step "Install Keycloak ${KEYCLOAK_VERSION_OLD}"
# Helm waits until both pods pass their readiness probe (a few minutes).
deploy_keycloak "${KEYCLOAK_VERSION_OLD}"

# Remember which Keycloak version is running.
state_set KEYCLOAK_ACTIVE_VERSION "${KEYCLOAK_VERSION_OLD}"

# Announce the step.
step "Show the Keycloak pods and their disruption budget"
# Two pods, ideally in two different zones.
run kubectl --namespace keycloak get pods --output wide
# The budget keeps one pod running during node drains.
run kubectl --namespace keycloak get poddisruptionbudget

# Announce the step.
step "Show that the two pods found each other"
# Keycloak logs a "cluster view" line each time a pod joins; "(2)" means two
# members. "|| true" keeps the script going when the line is not found.
kubectl --namespace keycloak logs --selector app.kubernetes.io/name=keycloak --container keycloak --tail=-1 --prefix | grep "ISPN000094" | tail -n 2 || true
