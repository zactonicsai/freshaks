#!/usr/bin/env bash
# =============================================================================
# 40-postgres-install-new.sh — install the NEW PostgreSQL major version as a
# second Helm release with its own, empty data volume, next to the old one.
# A new major version cannot read the old data folder, so the data is copied
# in step 41. Nothing uses the new database yet.
# (Within the same major version this script simply updates the image.)
# Usage: ./scripts/upgrade/40-postgres-install-new.sh
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

# Helm release name of the new version, e.g. postgres-v18.
new_release="$(postgres_release "${POSTGRES_VERSION_NEW}")"

# Same major version: a minor update keeps the data folder.
if [[ "${new_release}" == "${POSTGRES_ACTIVE_RELEASE}" ]]; then
  # Announce the step.
  step "Minor update of ${new_release} to ${POSTGRES_VERSION_NEW} (same data folder)"
  # The single pod restarts with the new image; the database is away for some seconds.
  deploy_postgres "${POSTGRES_VERSION_NEW}"
  # Remember the version.
  state_set POSTGRES_ACTIVE_VERSION "${POSTGRES_VERSION_NEW}"
  # Nothing else to do; steps 41 and 42 are not needed.
  exit 0
fi

# Announce the step.
step "Install PostgreSQL ${POSTGRES_VERSION_NEW} as Helm release ${new_release}"
# Its first start creates an empty database "keycloak" with the same passwords.
deploy_postgres "${POSTGRES_VERSION_NEW}"

# Remember the candidate for steps 41 and 42.
state_set POSTGRES_CANDIDATE_RELEASE "${new_release}"

# Announce the step.
step "Show both database servers"
# Version of the new server.
run pg_sql "${new_release}" postgres "SELECT version();"
# Old and new pod side by side; the Service "postgres" still points at the old one.
run kubectl --namespace postgres get pods,services --output wide
