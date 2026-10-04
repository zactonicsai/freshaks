#!/usr/bin/env bash
# =============================================================================
# keycloak-db-restore.sh — replace the Keycloak database with a dump from the
# shared backup volume. This is the data half of a Keycloak rollback in the
# Terraform example (Terraform itself cannot restore data).
# Before: Keycloak is stopped (keycloak_replicas = 0, applied).
# After:  set keycloak_version back to the old version and keycloak_replicas
#         = 2, then apply layer 3.
# Usage: ./terraform/scripts/keycloak-db-restore.sh DUMP_FILE
#        DUMP_FILE is a file name in /backups, as printed by
#        ./scripts/upgrade/01-backup-postgres.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"
# Load the "how to deploy each component" functions (pg_sql and friends).
# shellcheck source=../../scripts/lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The active PostgreSQL instance (written by sync-local-state.sh).
require_state POSTGRES_ACTIVE_RELEASE "terraform/scripts/sync-local-state.sh"
# The dump file: first argument.
file="${1:?usage: keycloak-db-restore.sh DUMP_FILE}"
# Pod of the active database instance.
pod="${POSTGRES_ACTIVE_RELEASE}-0"

# Announce the step.
step "Check that Keycloak is stopped"
# Count the Keycloak pods (tr removes the spaces macOS wc prints).
running="$(kubectl --namespace keycloak get pods --selector app.kubernetes.io/name=keycloak --no-headers 2>/dev/null | wc -l | tr -d ' ')"
# A running Keycloak must not see its database disappear.
if (( running > 0 )); then fail "Keycloak is running. Set keycloak_replicas = 0 in terraform/03-workloads and apply first."; fi
# Report success.
ok "Keycloak is stopped"

# Announce the step.
step "Check that the dump exists"
# "test -s" succeeds for a file that exists and is not empty.
run kubectl --namespace postgres exec "${pod}" --container postgres -- test -s "/backups/${file}"

# Ask before destroying data.
confirm "Replace the Keycloak database in ${POSTGRES_ACTIVE_RELEASE} with ${file}? Changes made since that dump are lost." || fail "stopped by user"

# Announce the step.
step "Replace the database with an empty one"
# WITH (FORCE) also closes connections that are still open.
run pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "DROP DATABASE IF EXISTS keycloak WITH (FORCE);"
# Same owner and encoding as at install time.
run pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "CREATE DATABASE keycloak OWNER keycloak ENCODING 'UTF8';"

# Announce the step.
step "Restore the dump"
# All or nothing (--single-transaction). The password comes from the pod's environment.
run kubectl --namespace postgres exec "${pod}" --container postgres -- bash -c "PGPASSWORD=\"\${KEYCLOAK_DB_PASSWORD}\" pg_restore --host 127.0.0.1 --username keycloak --dbname keycloak --no-owner --no-acl --single-transaction /backups/${file}"
# Fresh statistics for the query planner.
run pg_sql "${POSTGRES_ACTIVE_RELEASE}" keycloak "ANALYZE;"
# Final message.
ok "database restored. Next: set keycloak_version and keycloak_replicas in terraform/03-workloads and apply."
