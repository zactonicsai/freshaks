#!/usr/bin/env bash
# =============================================================================
# 03-delete-postgres.sh — remove every PostgreSQL release AND its data volume.
# The dumps on the shared backup volume stay until 05-delete-nfs-storage.sh.
# Usage: ./scripts/destroy/03-delete-postgres.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster
# Ask before destroying data.
confirm "Remove all PostgreSQL releases and DELETE their data volumes?" || fail "stopped by user"

# Every Helm release in the namespace is a PostgreSQL release (postgres-v14, postgres-v18, ...).
for release in $(helm list --namespace postgres --short); do
  # Announce the step.
  step "Uninstall Helm release ${release}"
  # Removes the StatefulSet, the headless Service and the ConfigMap.
  helm_remove "${release}" postgres
  # Announce the step.
  step "Delete the data volume of ${release}"
  # Helm never deletes the volumes of a StatefulSet; do it by hand.
  run kubectl --namespace postgres delete persistentvolumeclaim "data-${release}-0" --ignore-not-found
done

# Announce the step.
step "Delete the objects that were created with kubectl"
# The stable Service, the shared ServiceAccount and the credentials secret.
run kubectl --namespace postgres delete service/postgres serviceaccount/postgres secret/postgres-credentials --ignore-not-found

# Forget the PostgreSQL facts.
for key in POSTGRES_ACTIVE_RELEASE POSTGRES_ACTIVE_VERSION POSTGRES_PREVIOUS_RELEASE POSTGRES_PREVIOUS_VERSION POSTGRES_CANDIDATE_RELEASE POSTGRES_MIGRATION_DUMP; do
  # An empty value means "not known".
  state_set "${key}" ""
done
