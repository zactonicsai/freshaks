#!/usr/bin/env bash
# =============================================================================
# postgres-migrate.sh — copy the Keycloak database from one PostgreSQL
# instance to another (dump and restore). This is the one step of the
# PostgreSQL upgrade that Terraform cannot do: Terraform describes what should
# exist, it does not move data.
# Before: both instances are listed in postgres_instances, and Keycloak is
#         stopped (keycloak_replicas = 0, applied).
# After:  set postgres_active_release to the new instance and
#         keycloak_replicas = 2, then apply layer 3.
# Usage: ./terraform/scripts/postgres-migrate.sh OLD_RELEASE NEW_RELEASE
#        e.g. ./terraform/scripts/postgres-migrate.sh postgres-v14 postgres-v18
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"
# Load the "how to deploy each component" functions (pg_sql and friends).
# shellcheck source=../../scripts/lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# Old instance: first argument.
old="${1:?usage: postgres-migrate.sh OLD_RELEASE NEW_RELEASE}"
# New instance: second argument.
new="${2:?usage: postgres-migrate.sh OLD_RELEASE NEW_RELEASE}"
# Name of the dump file on the shared backup volume.
file="keycloak-migration-$(date +%Y%m%d-%H%M%S).dump"

# Announce the step.
step "Check that Keycloak is stopped"
# Count the Keycloak pods (tr removes the spaces macOS wc prints).
running="$(kubectl --namespace keycloak get pods --selector app.kubernetes.io/name=keycloak --no-headers 2>/dev/null | wc -l | tr -d ' ')"
# A running Keycloak would keep writing to the old database during the copy.
if (( running > 0 )); then fail "Keycloak is running. Set keycloak_replicas = 0 in terraform/03-workloads and apply first."; fi
# Report success.
ok "Keycloak is stopped"

# Announce the step.
step "Dump ${old} with the pg_dump of ${new}"
# Always dump with the tools of the version you are moving TO. The command
# runs in the new pod; the password comes from the pod's environment.
run kubectl --namespace postgres exec "${new}-0" --container postgres -- bash -c "PGPASSWORD=\"\${KEYCLOAK_DB_PASSWORD}\" pg_dump --host ${old}.postgres.svc.cluster.local --username keycloak --dbname keycloak --format custom --file /backups/${file}"

# Announce the step.
step "Restore into ${new}"
# All or nothing (--single-transaction); objects from an earlier attempt are
# dropped first (--clean --if-exists).
run kubectl --namespace postgres exec "${new}-0" --container postgres -- bash -c "PGPASSWORD=\"\${KEYCLOAK_DB_PASSWORD}\" pg_restore --host 127.0.0.1 --username keycloak --dbname keycloak --no-owner --no-acl --clean --if-exists --single-transaction /backups/${file}"
# Fresh statistics for the query planner.
run pg_sql "${new}" keycloak "ANALYZE;"

# Announce the step.
step "Compare old and new database"
# Four numbers: tables | users | clients | realms.
old_fingerprint="$(keycloak_db_fingerprint "${old}")"
# The same four numbers from the new instance.
new_fingerprint="$(keycloak_db_fingerprint "${new}")"
# Show both.
info "old ${old}: ${old_fingerprint}   new ${new}: ${new_fingerprint}"
# They must be identical.
[[ "${old_fingerprint}" == "${new_fingerprint}" ]] || fail "The copy differs from the original. The old database is untouched."
# Final message.
ok "copy complete. Next: postgres_active_release = \"${new}\" and keycloak_replicas = 2, then apply terraform/03-workloads."
