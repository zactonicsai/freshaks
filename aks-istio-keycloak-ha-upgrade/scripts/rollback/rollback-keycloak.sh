#!/usr/bin/env bash
# =============================================================================
# rollback-keycloak.sh — go back to the Keycloak version that ran before
# 30-keycloak-upgrade.sh.
# The new Keycloak changed the database tables, and the old version cannot
# read them. So the rollback has two parts: restore the database dump that was
# taken right before the upgrade, then "helm rollback" to the old release.
# Everything that changed in Keycloak after the upgrade (new users, changed
# passwords, sessions) is lost.
# Usage: ./scripts/rollback/rollback-keycloak.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# Helm revision of the old version, recorded by the upgrade script.
require_state KEYCLOAK_ROLLBACK_REVISION "scripts/upgrade/30-keycloak-upgrade.sh"
# The old version number.
require_state KEYCLOAK_ROLLBACK_VERSION "scripts/upgrade/30-keycloak-upgrade.sh"
# The dump taken before the upgrade.
require_state KEYCLOAK_ROLLBACK_DUMP "scripts/upgrade/30-keycloak-upgrade.sh"
# The active PostgreSQL release.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/19-install-postgres.sh"
# The host names are needed for the check at the end.
require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"
# The public address too.
require_state PUBLIC_IP "scripts/install/04-create-public-ip.sh"

# Pod of the active database server.
pod="${POSTGRES_ACTIVE_RELEASE}-0"

# Ask before destroying data.
confirm "Roll Keycloak back to ${KEYCLOAK_ROLLBACK_VERSION} and restore the database from ${KEYCLOAK_ROLLBACK_DUMP}? Changes made in Keycloak since then are lost." || fail "stopped by user"

# Announce the step.
step "Check that the dump still exists on the backup volume"
# "test -s" succeeds for a file that exists and is not empty.
run kubectl --namespace postgres exec "${pod}" --container postgres -- test -s "/backups/${KEYCLOAK_ROLLBACK_DUMP}"

# Announce the step.
step "Stop Keycloak"
# Zero pods, whatever version is deployed right now. No pod may touch the
# database while it is being replaced.
deploy_keycloak "${KEYCLOAK_ROLLBACK_VERSION}" --set replicaCount=0
# Wait until the pods have really ended.
wait_pods_gone keycloak app.kubernetes.io/name=keycloak 300

# Announce the step.
step "Replace the database with an empty one"
# WITH (FORCE) also closes connections that are still open.
run pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "DROP DATABASE IF EXISTS keycloak WITH (FORCE);"
# Same owner and encoding as at install time.
run pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "CREATE DATABASE keycloak OWNER keycloak ENCODING 'UTF8';"

# Announce the step.
step "Restore the dump"
# --single-transaction: all or nothing. The password comes from the pod's environment.
run kubectl --namespace postgres exec "${pod}" --container postgres -- bash -c "PGPASSWORD=\"\${KEYCLOAK_DB_PASSWORD}\" pg_restore --host 127.0.0.1 --username keycloak --dbname keycloak --no-owner --no-acl --single-transaction /backups/${KEYCLOAK_ROLLBACK_DUMP}"
# Fresh statistics for the query planner.
run pg_sql "${POSTGRES_ACTIVE_RELEASE}" keycloak "ANALYZE;"

# Announce the step.
step "Roll the Helm release back to revision ${KEYCLOAK_ROLLBACK_REVISION}"
# That revision is the old version with two pods and its old settings.
# Helm only keeps the last 10 revisions of a release; when the recorded one
# is gone, deploy the old version with the normal deploy function instead.
if ! run helm rollback keycloak "${KEYCLOAK_ROLLBACK_REVISION}" --namespace keycloak --wait --timeout "${HELM_TIMEOUT}"; then
  # Tell the user why the second way is used.
  warn "helm rollback did not work - deploying Keycloak ${KEYCLOAK_ROLLBACK_VERSION} again instead"
  # Same result: the old image with the settings file for old versions.
  deploy_keycloak "${KEYCLOAK_ROLLBACK_VERSION}"
fi
# The old version is the active one again.
state_set KEYCLOAK_ACTIVE_VERSION "${KEYCLOAK_ROLLBACK_VERSION}"

# Announce the step.
step "Check that Keycloak answers"
# The discovery document must be served again.
wait_http "keycloak discovery document" 200 300 "https://keycloak.${BASE_DOMAIN}/realms/demo/.well-known/openid-configuration"
# Show the pods and their image.
run kubectl --namespace keycloak get pods --output wide
