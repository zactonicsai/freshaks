#!/usr/bin/env bash
# =============================================================================
# 41-postgres-migrate-data.sh — copy the Keycloak database from the old
# PostgreSQL to the new one (dump and restore).
# Keycloak is stopped first so that nothing changes during the copy; logins
# are unavailable until step 42 has finished (a few minutes).
# The old database is only read, never changed: it stays the way back.
# Usage: ./scripts/upgrade/41-postgres-migrate-data.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The old (active) server must be known.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/19-install-postgres.sh"
# The new server must be installed.
require_state POSTGRES_CANDIDATE_RELEASE "scripts/upgrade/40-postgres-install-new.sh"
# The running Keycloak version is needed to stop and start it.
require_state KEYCLOAK_ACTIVE_VERSION "scripts/install/20-install-keycloak.sh"

# Short names: the old (active) and the new (candidate) release.
old="${POSTGRES_ACTIVE_RELEASE}"
# The new release.
new="${POSTGRES_CANDIDATE_RELEASE}"
# Name of the dump file on the shared backup volume.
file="keycloak-migration-$(date +%Y%m%d-%H%M%S).dump"

# Announce the step.
step "Stop Keycloak so that nothing is written during the copy"
# Scale to zero through Helm (logins are unavailable from now on).
deploy_keycloak "${KEYCLOAK_ACTIVE_VERSION}" --set replicaCount=0
# Wait until the pods have really ended.
wait_pods_gone keycloak app.kubernetes.io/name=keycloak 300

# Announce the step.
step "Dump the old database with the NEW version of pg_dump"
# Rule from the PostgreSQL manual: always dump with the pg_dump of the version
# you are moving TO. So the command runs in the new pod and connects over the
# network to the old server. The password comes from the pod's environment.
run kubectl --namespace postgres exec "${new}-0" --container postgres -- bash -c "PGPASSWORD=\"\${KEYCLOAK_DB_PASSWORD}\" pg_dump --host ${old}.postgres.svc.cluster.local --username keycloak --dbname keycloak --format custom --file /backups/${file}"

# Announce the step.
step "Restore the dump into the new server"
#   --no-owner / --no-acl   objects belong to the role that restores (keycloak)
#   --clean --if-exists     drop objects from an earlier attempt first
#   --single-transaction    all or nothing: an error leaves the database empty
run kubectl --namespace postgres exec "${new}-0" --container postgres -- bash -c "PGPASSWORD=\"\${KEYCLOAK_DB_PASSWORD}\" pg_restore --host 127.0.0.1 --username keycloak --dbname keycloak --no-owner --no-acl --clean --if-exists --single-transaction /backups/${file}"

# Announce the step.
step "Refresh the planner statistics"
# A restored database has no statistics yet; without them queries are slow.
run pg_sql "${new}" keycloak "ANALYZE;"

# Announce the step.
step "Compare old and new database"
# Four numbers: tables | users | clients | realms.
old_fingerprint="$(keycloak_db_fingerprint "${old}")"
# The same four numbers from the new server.
new_fingerprint="$(keycloak_db_fingerprint "${new}")"
# Show both.
info "old ${old}: ${old_fingerprint}   new ${new}: ${new_fingerprint}"
# They must be identical.
[[ "${old_fingerprint}" == "${new_fingerprint}" ]] || fail "The copy differs from the original. The old database is untouched; run rollback-postgres.sh to start Keycloak on it again."
# Report success.
ok "the copy matches the original"

# Announce the step.
step "Keep a copy of the dump outside the cluster"
# kubectl cp copies the file from the pod to this machine.
run kubectl --namespace postgres cp --container postgres "${new}-0:/backups/${file}" "${BACKUP_DIR}/${file}"
# Remember the file; step 42 checks that the migration has run.
state_set POSTGRES_MIGRATION_DUMP "${file}"
# Explain the state.
warn "Keycloak is stopped. Next: 42-postgres-switch.sh (or scripts/rollback/rollback-postgres.sh to start Keycloak on the old database again)."
