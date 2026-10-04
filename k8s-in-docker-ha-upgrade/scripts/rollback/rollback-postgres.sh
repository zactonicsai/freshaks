#!/usr/bin/env bash
# =============================================================================
# rollback-postgres.sh — undo 40-postgres-migrate.sh. Two cases:
#   A. The migration stopped BEFORE the switch (Keycloak is stopped, the
#      Service still points at the old server): just start Keycloak again.
#      Nothing is lost.
#   B. The Service already points at the new server: stop Keycloak, point the
#      Service back at the old server (which was never changed and still
#      runs), start Keycloak.
#      COST: everything written since the switch is lost.
# Usage: ./scripts/rollback/rollback-postgres.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# Keycloak is stopped and started below.
require_state KEYCLOAK_ACTIVE_VERSION "scripts/install/07-install-keycloak.sh"
# The active database must be known.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/06-install-postgres.sh"
# The old release; only set after the switch.
previous="${POSTGRES_PREVIOUS_RELEASE:-}"

# Case A: the switch has not happened.
if [[ -z "${previous}" ]]; then
  # Announce the step.
  step "The Service still points at ${POSTGRES_ACTIVE_RELEASE}: start Keycloak again"
  # Back to the normal number of pods, on the database it always used.
  deploy_keycloak "${KEYCLOAK_ACTIVE_VERSION}"
  # Keycloak must answer again.
  wait_http "keycloak discovery document" 200 300 "https://keycloak.${PUBLIC_DOMAIN}/realms/demo/.well-known/openid-configuration"
  # Done.
  exit 0
fi

# Case B: switch back. Ask before losing data.
confirm "Switch back from ${POSTGRES_ACTIVE_RELEASE} to ${previous}? Data written since the switch is lost." || fail "stopped by user"

# Announce the step.
step "Stop Keycloak"
# Scale to zero through Helm.
deploy_keycloak "${KEYCLOAK_ACTIVE_VERSION}" --set replicaCount=0
# Wait until the last pod is gone, so no connection to the new server is open.
wait_pods_gone keycloak app.kubernetes.io/name=keycloak 300

# Announce the step.
step "Make sure the old server ${previous} is running"
# One pod again, in case it was parked with 41-postgres-retire-old.sh.
deploy_postgres "${POSTGRES_PREVIOUS_VERSION}" 1

# Announce the step.
step "Point Service 'postgres' back at ${previous}"
# The old release is active again ...
state_set POSTGRES_ACTIVE_RELEASE "${previous}"
# ... with its version.
state_set POSTGRES_ACTIVE_VERSION "${POSTGRES_PREVIOUS_VERSION}"
# There is no "previous" release any more. (The new server stays installed;
# running 40-postgres-migrate.sh again copies the data afresh.)
state_set POSTGRES_PREVIOUS_RELEASE ""
# Forget its version too.
state_set POSTGRES_PREVIOUS_VERSION ""
# Re-apply the Service with the old release in its selector.
kapply k8s/postgres/service-active.yaml

# Announce the step.
step "Start Keycloak on the old database"
# Back to the normal number of pods.
deploy_keycloak "${KEYCLOAK_ACTIVE_VERSION}"

# Announce the step.
step "Check the result"
# The version of the server behind the Service.
run pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "SELECT version();"
# Keycloak must answer again.
wait_http "keycloak discovery document" 200 300 "https://keycloak.${PUBLIC_DOMAIN}/realms/demo/.well-known/openid-configuration"
