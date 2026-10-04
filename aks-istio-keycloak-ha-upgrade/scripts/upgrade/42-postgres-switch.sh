#!/usr/bin/env bash
# =============================================================================
# 42-postgres-switch.sh — make the new PostgreSQL the active one: point the
# stable Service "postgres" at it and start Keycloak again.
# The old server keeps running with its data, untouched, as the way back.
# Usage: ./scripts/upgrade/42-postgres-switch.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The new server must be installed ...
require_state POSTGRES_CANDIDATE_RELEASE "scripts/upgrade/40-postgres-install-new.sh"
# ... and filled with the data.
require_state POSTGRES_MIGRATION_DUMP "scripts/upgrade/41-postgres-migrate-data.sh"
# The running Keycloak version is needed to start it.
require_state KEYCLOAK_ACTIVE_VERSION "scripts/install/20-install-keycloak.sh"
# The old (active) server must be known.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/19-install-postgres.sh"
# The host names are needed for the check at the end.
require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"
# The public address too.
require_state PUBLIC_IP "scripts/install/04-create-public-ip.sh"

# Announce the step.
step "Check that Keycloak is still stopped"
# If Keycloak ran after the copy was made, the copy is out of date.
running="$(kubectl --namespace keycloak get pods --selector app.kubernetes.io/name=keycloak --no-headers 2>/dev/null | wc -l | tr -d ' ')"
# Refuse to switch to a stale copy.
if (( running > 0 )); then fail "Keycloak is running, so the copied data may be out of date. Run 41-postgres-migrate-data.sh again."; fi
# Report success.
ok "Keycloak is stopped - no connection to the old database is open"

# Announce the step.
step "Point Service 'postgres' at ${POSTGRES_CANDIDATE_RELEASE}"
# Remember the old release and version: they are the way back.
state_set POSTGRES_PREVIOUS_RELEASE "${POSTGRES_ACTIVE_RELEASE}"
# Version of the old release.
state_set POSTGRES_PREVIOUS_VERSION "${POSTGRES_ACTIVE_VERSION:-${POSTGRES_VERSION_OLD}}"
# The candidate becomes the active release ...
state_set POSTGRES_ACTIVE_RELEASE "${POSTGRES_CANDIDATE_RELEASE}"
# ... with the new version.
state_set POSTGRES_ACTIVE_VERSION "${POSTGRES_VERSION_NEW}"
# No candidate any more.
state_set POSTGRES_CANDIDATE_RELEASE ""
# Re-apply the Service; its selector now names the new release. A selector
# change only affects NEW connections - which is why Keycloak had to be stopped.
kapply "${ROOT_DIR}/k8s/postgres/service-active.yaml"

# Announce the step.
step "Start Keycloak ${KEYCLOAK_ACTIVE_VERSION} on the new database"
# Back to two pods; Helm waits until both are ready.
deploy_keycloak "${KEYCLOAK_ACTIVE_VERSION}"

# Announce the step.
step "Check the result"
# The new server reports its version.
run pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "SELECT version();"
# The Service now has the new pod as its endpoint.
run kubectl --namespace postgres get endpointslices --selector kubernetes.io/service-name=postgres
# Keycloak must answer again.
wait_http "keycloak discovery document" 200 300 "https://keycloak.${BASE_DOMAIN}/realms/demo/.well-known/openid-configuration"
# Explain the state.
info "the old release ${POSTGRES_PREVIOUS_RELEASE} still runs. Way back: scripts/rollback/rollback-postgres.sh. When you are sure: 43-postgres-retire-old.sh"
