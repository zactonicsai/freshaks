#!/usr/bin/env bash
# =============================================================================
# rollback-keycloak.sh — go back to the Keycloak version that ran before
# 30-keycloak-upgrade.sh.
# The new version has changed the database, and the old version cannot read
# the changed tables. So the database is put back from the dump that the
# upgrade script took while Keycloak was stopped:
#   1. stop Keycloak
#   2. replace the database with the dump
#   3. start the old version (helm rollback)
# COST: everything that changed in Keycloak since the upgrade is lost
# (new users, password changes, sessions).
# Usage: ./scripts/rollback/rollback-keycloak.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# The upgrade script recorded the Helm revision to go back to ...
require_state KEYCLOAK_ROLLBACK_REVISION "scripts/upgrade/30-keycloak-upgrade.sh"
# ... the version that goes with it ...
require_state KEYCLOAK_ROLLBACK_VERSION "scripts/upgrade/30-keycloak-upgrade.sh"
# ... and the dump of the database in its old format.
require_state KEYCLOAK_ROLLBACK_DUMP "scripts/upgrade/30-keycloak-upgrade.sh"
# The active database must be known.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/06-install-postgres.sh"
# Ask before destroying data.
confirm "Roll Keycloak back to ${KEYCLOAK_ROLLBACK_VERSION} and restore the database from ${KEYCLOAK_ROLLBACK_DUMP}? Changes made in Keycloak since then are lost." || fail "stopped by user"

# Announce the step.
step "Check that the dump still exists on the backup volume"
# "test -s" succeeds for a file that exists and is not empty.
run kubectl --namespace postgres exec "${POSTGRES_ACTIVE_RELEASE}-0" --container postgres -- test -s "/backups/${KEYCLOAK_ROLLBACK_DUMP}"

# Announce the step.
step "Stop Keycloak"
# Scale to zero through Helm (with the OLD version's settings, so that a
# failed start of the new version cannot get in the way).
deploy_keycloak "${KEYCLOAK_ROLLBACK_VERSION}" --set replicaCount=0
# Wait until the last pod is gone.
wait_pods_gone keycloak app.kubernetes.io/name=keycloak 300

# Announce the step.
step "Replace the database with the dump"
# Drop, create, restore, refresh statistics (see pg_restore_keycloak in deploy.sh).
pg_restore_keycloak "${KEYCLOAK_ROLLBACK_DUMP}"

# Announce the step.
step "Roll the Helm release back to revision ${KEYCLOAK_ROLLBACK_REVISION}"
# That revision is the old version with its normal number of pods. If Helm has
# already pruned it (it keeps 10), deploying the old version again is the same.
if ! run helm rollback keycloak "${KEYCLOAK_ROLLBACK_REVISION}" --namespace keycloak --wait --timeout "${HELM_TIMEOUT}"; then
  # Say what happens instead.
  warn "helm rollback did not work - deploying Keycloak ${KEYCLOAK_ROLLBACK_VERSION} again instead"
  # Old version, default settings.
  deploy_keycloak "${KEYCLOAK_ROLLBACK_VERSION}"
fi
# Remember which version is active again.
state_set KEYCLOAK_ACTIVE_VERSION "${KEYCLOAK_ROLLBACK_VERSION}"

# Announce the step.
step "Check that Keycloak answers"
# The discovery document must be served again.
wait_http "keycloak discovery document" 200 300 "https://keycloak.${PUBLIC_DOMAIN}/realms/demo/.well-known/openid-configuration"
# Pods and nodes.
run kubectl --namespace keycloak get pods --output wide
