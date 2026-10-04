#!/usr/bin/env bash
# =============================================================================
# 07-install-keycloak.sh — install Keycloak (old version) with two pods.
# On its very first start Keycloak imports the realm "demo": two OIDC clients
# (app1, app2), the roles "user" and "admin" and the test users alice, bob
# and carol.
# Usage: ./scripts/install/07-install-keycloak.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# PostgreSQL must be installed first.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/06-install-postgres.sh"
# The database password was generated together with PostgreSQL.
[[ -n "${KEYCLOAK_DB_PASSWORD:-}" ]] || fail "No database password yet. Run scripts/install/06-install-postgres.sh first."

# Announce the step.
step "Generate passwords and client secrets (first run only)"
# Password of the Keycloak administrator "admin".
secret_ensure KEYCLOAK_ADMIN_PASSWORD
# OIDC client secret of application 1.
secret_ensure APP1_CLIENT_SECRET
# OIDC client secret of application 2.
secret_ensure APP2_CLIENT_SECRET
# Password of the test users alice, bob and carol ("Demo-" + random part).
secret_ensure TEST_USER_PASSWORD "Demo-"
# Admin login and database password as a Kubernetes secret (piped in, so the
# values never appear on a command line or in the log).
kubectl_stdin apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-credentials
  namespace: keycloak
type: Opaque
stringData:
  admin-username: "admin"
  admin-password: "${KEYCLOAK_ADMIN_PASSWORD}"
  db-password: "${KEYCLOAK_DB_PASSWORD}"
YAML

# Install the old version unless an upgrade has already moved on.
version="${KEYCLOAK_ACTIVE_VERSION:-${KEYCLOAK_VERSION_OLD}}"
# Announce the step.
step "Install Keycloak ${version} (the first start takes a few minutes)"
# Two pods that share their caches; settings in helm/values/keycloak-*.yaml.
deploy_keycloak "${version}"
# Remember which version is active.
state_set KEYCLOAK_ACTIVE_VERSION "${version}"

# Announce the step.
step "Check that Keycloak answers through the gateway"
# The OIDC "discovery document" of realm demo lists all login endpoints.
wait_http "keycloak discovery document" 200 300 "https://keycloak.${PUBLIC_DOMAIN}/realms/demo/.well-known/openid-configuration"
# Show the pods and where they run.
run kubectl --namespace keycloak get pods --output wide
