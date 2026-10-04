#!/usr/bin/env bash
# =============================================================================
# 01-backup-postgres.sh — dump the Keycloak database before anything changes.
# The dump is written to the shared backup volume in the cluster AND copied to
# .state/backups on this machine.
# Usage: ./scripts/upgrade/01-backup-postgres.sh [LABEL]   (default label: pre-upgrade)
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The active PostgreSQL release must be known.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/19-install-postgres.sh"

# Announce the step.
step "Dump the Keycloak database of ${POSTGRES_ACTIVE_RELEASE}"
# pg_backup runs pg_dump in the pod and copies the file to this machine.
pg_backup "${1:-pre-upgrade}"

# Announce the step.
step "List the backups"
# Dumps on the shared volume inside the cluster.
run kubectl --namespace postgres exec "${POSTGRES_ACTIVE_RELEASE}-0" --container postgres -- ls -l /backups
# Copies on this machine.
run ls -l "${BACKUP_DIR}"
