#!/usr/bin/env bash
# =============================================================================
# rollback-postgres.sh — go back to the old PostgreSQL server.
# Case A (copy made, Service not switched yet): just start Keycloak again on
#         the database it used before. Nothing is lost.
# Case B (Service already switched): stop Keycloak, point the Service back at
#         the old server, start Keycloak. Everything written to the NEW server
#         since the switch is lost (the old server never saw it).
# This works as long as the old release was not deleted (43 --delete).
# Usage: ./scripts/rollback/rollback-postgres.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The running Keycloak version is needed to stop and start it.
require_state KEYCLOAK_ACTIVE_VERSION "scripts/install/20-install-keycloak.sh"
# The active PostgreSQL release.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/19-install-postgres.sh"
# The host names are needed for the check at the end.
require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"
# The public address too.
require_state PUBLIC_IP "scripts/install/04-create-public-ip.sh"

# The release that was active before the switch (empty when not switched).
previous="${POSTGRES_PREVIOUS_RELEASE:-}"

# Case A: the Service was never switched.
if [[ -z "${previous}" ]]; then
  # Announce the step.
  step "The Service still points at ${POSTGRES_ACTIVE_RELEASE}: start Keycloak again"
  # Back to two pods on the database that was never changed.
  deploy_keycloak "${KEYCLOAK_ACTIVE_VERSION}"
  # Forget the half-done migration, so step 42 cannot switch to a stale copy.
  state_set POSTGRES_MIGRATION_DUMP ""
  # Keycloak must answer again.
  wait_http "keycloak discovery document" 200 300 "https://keycloak.${BASE_DOMAIN}/realms/demo/.well-known/openid-configuration"
  # Done.
  exit 0
fi

# Case B: switch back.
confirm "Switch back from ${POSTGRES_ACTIVE_RELEASE} to ${previous}? Data written since the switch is lost." || fail "stopped by user"

# Announce the step.
step "Stop Keycloak"
# No pod may hold a connection while the Service changes its target.
deploy_keycloak "${KEYCLOAK_ACTIVE_VERSION}" --set replicaCount=0
# Wait until the pods have really ended.
wait_pods_gone keycloak app.kubernetes.io/name=keycloak 300

# Announce the step.
step "Make sure the old server ${previous} is running"
# Starts it again when it was parked with zero pods; otherwise changes nothing.
deploy_postgres "${POSTGRES_PREVIOUS_VERSION}" 1

# Announce the step.
step "Point Service 'postgres' back at ${previous}"
# The release we are leaving becomes the candidate again (steps 41 and 42 can
# be repeated later).
state_set POSTGRES_CANDIDATE_RELEASE "${POSTGRES_ACTIVE_RELEASE}"
# The old release is the active one again ...
state_set POSTGRES_ACTIVE_RELEASE "${previous}"
# ... with its old version.
state_set POSTGRES_ACTIVE_VERSION "${POSTGRES_PREVIOUS_VERSION}"
# Nothing to go back to any more.
state_set POSTGRES_PREVIOUS_RELEASE ""
# Forget its version too.
state_set POSTGRES_PREVIOUS_VERSION ""
# A new migration must make a fresh copy first.
state_set POSTGRES_MIGRATION_DUMP ""
# Re-apply the Service with the old selector.
kapply "${ROOT_DIR}/k8s/postgres/service-active.yaml"

# Announce the step.
step "Start Keycloak on the old database"
# Back to two pods.
deploy_keycloak "${KEYCLOAK_ACTIVE_VERSION}"

# Announce the step.
step "Check the result"
# The old server reports its version.
run pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "SELECT version();"
# Keycloak must answer again.
wait_http "keycloak discovery document" 200 300 "https://keycloak.${BASE_DOMAIN}/realms/demo/.well-known/openid-configuration"
