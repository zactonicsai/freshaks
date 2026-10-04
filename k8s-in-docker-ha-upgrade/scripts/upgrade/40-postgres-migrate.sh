#!/usr/bin/env bash
# =============================================================================
# 40-postgres-migrate.sh — move Keycloak's database to a new PostgreSQL major
# version (14 -> 18). A new major version cannot open the old data folder, so
# a SECOND server is installed and filled from a copy:
#   1. install the new server next to the old one (its own Helm release and volume)
#   2. stop Keycloak                              (logins are down from here ...)
#   3. dump the old database with the NEW pg_dump, restore it into the new server
#   4. compare old and new
#   5. point the Service "postgres" at the new server
#   6. start Keycloak                             (... to here)
# The old server is never changed and keeps running: rollback-postgres.sh
# switches back to it.
# Usage: ./scripts/upgrade/40-postgres-migrate.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# The active database must be known.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/06-install-postgres.sh"
# Keycloak is stopped and started below.
require_state KEYCLOAK_ACTIVE_VERSION "scripts/install/07-install-keycloak.sh"
# Release name of the new version, e.g. postgres-v18.
new="$(postgres_release "${POSTGRES_VERSION_NEW}")"
# The release that is active now, e.g. postgres-v14.
old="${POSTGRES_ACTIVE_RELEASE}"

# Same major version: a minor update keeps the data folder and needs no migration.
if [[ "${new}" == "${old}" ]]; then
  # Nothing to do when the exact version already runs.
  if [[ "${POSTGRES_ACTIVE_VERSION:-}" == "${POSTGRES_VERSION_NEW}" ]]; then ok "PostgreSQL already runs ${POSTGRES_VERSION_NEW}"; exit 0; fi
  # Announce the step.
  step "Minor update of ${new} to ${POSTGRES_VERSION_NEW} (same data folder)"
  # The single pod restarts with the new image.
  deploy_postgres "${POSTGRES_VERSION_NEW}"
  # Remember the version.
  state_set POSTGRES_ACTIVE_VERSION "${POSTGRES_VERSION_NEW}"
  # Done.
  exit 0
fi
# Last chance to stop.
confirm "Move the database from ${old} to ${new}? Logins will be unavailable for a few minutes." || fail "stopped by user"

# Announce the step.
step "Install PostgreSQL ${POSTGRES_VERSION_NEW} as Helm release ${new}"
# Its own StatefulSet and its own (empty) data volume; nothing uses it yet.
deploy_postgres "${POSTGRES_VERSION_NEW}"
# Show both servers.
run kubectl --namespace postgres get pods --output wide

# Announce the step.
step "Stop Keycloak so that nothing is written during the copy"
# Scale to zero through Helm.
deploy_keycloak "${KEYCLOAK_ACTIVE_VERSION}" --set replicaCount=0
# Wait until the last pod is gone.
wait_pods_gone keycloak app.kubernetes.io/name=keycloak 300

# Announce the step.
step "Dump the old database with the NEW version of pg_dump"
# Name of the dump file on the shared backup volume.
file="keycloak-migration-$(date +%Y%m%d-%H%M%S).dump"
# Always dump with the tools of the version you are moving TO. The command
# runs in the new pod and connects to the old server over the network; the
# password comes from the pod's environment.
run kubectl --namespace postgres exec "${new}-0" --container postgres -- bash -c "PGPASSWORD=\"\${KEYCLOAK_DB_PASSWORD}\" pg_dump --host ${old}.postgres.svc.cluster.local --username keycloak --dbname keycloak --format custom --file /backups/${file}"

# Announce the step.
step "Restore the dump into the new server"
# --single-transaction: all or nothing. --clean --if-exists: drop objects
# from an earlier attempt first. --no-owner --no-acl: do not replay owners
# and permissions (their defaults changed in PostgreSQL 15).
run kubectl --namespace postgres exec "${new}-0" --container postgres -- bash -c "PGPASSWORD=\"\${KEYCLOAK_DB_PASSWORD}\" pg_restore --host 127.0.0.1 --username keycloak --dbname keycloak --no-owner --no-acl --clean --if-exists --single-transaction /backups/${file}"
# A restored database has no statistics; without them queries are slow.
run pg_sql "${new}" keycloak "ANALYZE;"

# Announce the step.
step "Compare old and new database"
# Four numbers: tables | users | clients | realms.
old_fingerprint="$(keycloak_db_fingerprint "${old}")"
# The same four numbers from the new server.
new_fingerprint="$(keycloak_db_fingerprint "${new}")"
# Show both.
info "old ${old}: ${old_fingerprint}   new ${new}: ${new_fingerprint}"
# They must be identical. On failure Keycloak stays stopped on purpose.
[[ "${old_fingerprint}" == "${new_fingerprint}" ]] || fail "The copy differs from the original. The old database is untouched; run scripts/rollback/rollback-postgres.sh to start Keycloak on it again."
# Report success.
ok "the copy matches the original"
# Keep a copy of the dump outside the cluster.
run kubectl --namespace postgres cp --container postgres "${new}-0:/backups/${file}" "${BACKUP_DIR}/${file}"

# Announce the step.
step "Point Service 'postgres' at ${new}"
# Remember the old release as the way back ...
state_set POSTGRES_PREVIOUS_RELEASE "${old}"
# ... with its exact version.
state_set POSTGRES_PREVIOUS_VERSION "${POSTGRES_ACTIVE_VERSION:-${POSTGRES_VERSION_OLD}}"
# The new release becomes the active one.
state_set POSTGRES_ACTIVE_RELEASE "${new}"
# With its version.
state_set POSTGRES_ACTIVE_VERSION "${POSTGRES_VERSION_NEW}"
# Re-apply the Service; its selector now names the new release. Keycloak is
# stopped, so no connection to the old server is open.
kapply k8s/postgres/service-active.yaml

# Announce the step.
step "Start Keycloak ${KEYCLOAK_ACTIVE_VERSION} on the new database"
# Back to the normal number of pods.
deploy_keycloak "${KEYCLOAK_ACTIVE_VERSION}"

# Announce the step.
step "Check the result"
# The version of the server behind the Service.
run pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "SELECT version();"
# Keycloak must answer again.
wait_http "keycloak discovery document" 200 300 "https://keycloak.${PUBLIC_DOMAIN}/realms/demo/.well-known/openid-configuration"
# Explain what is left to do.
info "The old release ${old} still runs, untouched. Way back: scripts/rollback/rollback-postgres.sh. When you are sure: 41-postgres-retire-old.sh"
