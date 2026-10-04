#!/usr/bin/env bash
# =============================================================================
# 19-install-postgres.sh — install PostgreSQL (OLD version) with Helm and
# create the stable Service "postgres" that points at it with kubectl.
# The data folder is on the shared NFS storage.
# Usage: ./scripts/install/19-install-postgres.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster

# Helm release name of the old version, e.g. postgres-v14.
release="$(postgres_release "${POSTGRES_VERSION_OLD}")"

# Announce the step.
step "Create the ServiceAccount shared by all PostgreSQL releases"
# One identity for old and new version (used by the Istio AuthorizationPolicy).
kapply "${ROOT_DIR}/k8s/postgres/serviceaccount.yaml"

# Announce the step.
step "Install PostgreSQL ${POSTGRES_VERSION_OLD} as Helm release ${release}"
# One StatefulSet pod; on its first start it creates the role and the
# database "keycloak".
deploy_postgres "${POSTGRES_VERSION_OLD}"

# Remember which release is the active one ...
state_set POSTGRES_ACTIVE_RELEASE "${release}"
# ... and which PostgreSQL version it runs.
state_set POSTGRES_ACTIVE_VERSION "${POSTGRES_VERSION_OLD}"

# Announce the step.
step "Create the stable Service 'postgres' that points at ${release}"
# Keycloak only ever connects to postgres.postgres.svc.cluster.local.
kapply "${ROOT_DIR}/k8s/postgres/service-active.yaml"

# Announce the step.
step "Check that the database answers"
# Prints the exact server version.
run pg_sql "${release}" postgres "SELECT version();"
# Prints "keycloak" when the init script created the database.
run pg_sql "${release}" postgres "SELECT datname FROM pg_database WHERE datname = 'keycloak';"
# Show the pod and its two volumes (data + shared backups).
run kubectl --namespace postgres get pods,persistentvolumeclaims --output wide
