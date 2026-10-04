#!/usr/bin/env bash
# =============================================================================
# 06-install-postgres.sh — install PostgreSQL (old version) as Keycloak's
# database. Its data folder and the backup folder are NFS volumes.
# One Helm release per MAJOR version (postgres-v14); the Service "postgres"
# points at the active one. That is what makes the later upgrade a switch
# between two servers instead of a risky change in place.
# Usage: ./scripts/install/06-install-postgres.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster

# Announce the step.
step "Generate the database passwords (first run only) and store them as a secret"
# Password of the PostgreSQL superuser "postgres".
secret_ensure POSTGRES_PASSWORD
# Password of the database role "keycloak".
secret_ensure KEYCLOAK_DB_PASSWORD
# The manifest is piped into kubectl, so no password ever appears on a command
# line or in the log. Note: PostgreSQL reads its passwords only when the data
# folder is created; changing the secret later does not change the database.
kubectl_stdin apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: postgres
type: Opaque
stringData:
  postgres-password: "${POSTGRES_PASSWORD}"
  keycloak-db-password: "${KEYCLOAK_DB_PASSWORD}"
YAML

# Announce the step.
step "Create the ServiceAccount and the stable Service 'postgres'"
# On the first run the active release is the old version.
if [[ -z "${POSTGRES_ACTIVE_RELEASE:-}" ]]; then state_set POSTGRES_ACTIVE_RELEASE "$(postgres_release "${POSTGRES_VERSION_OLD}")"; fi
# And its exact version.
if [[ -z "${POSTGRES_ACTIVE_VERSION:-}" ]]; then state_set POSTGRES_ACTIVE_VERSION "${POSTGRES_VERSION_OLD}"; fi
# One identity for all PostgreSQL releases (named in the Istio AuthorizationPolicy).
kapply k8s/postgres/serviceaccount.yaml
# The one address Keycloak knows; its selector names the active release.
kapply k8s/postgres/service-active.yaml

# Announce the step.
step "Install PostgreSQL ${POSTGRES_ACTIVE_VERSION} as Helm release ${POSTGRES_ACTIVE_RELEASE}"
# A StatefulSet with one pod; the first start creates the database "keycloak".
deploy_postgres "${POSTGRES_ACTIVE_VERSION}"

# Announce the step.
step "Check the server"
# Ask the server for its version.
run pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "SELECT version();"
# The database and the role for Keycloak must exist.
run pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "SELECT datname FROM pg_database WHERE datname = 'keycloak';"
# Show pod, services and volumes.
run kubectl --namespace postgres get pods,services,persistentvolumeclaims --output wide
