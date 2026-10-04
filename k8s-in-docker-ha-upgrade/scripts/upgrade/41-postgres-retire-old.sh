#!/usr/bin/env bash
# =============================================================================
# 41-postgres-retire-old.sh — retire the old PostgreSQL server after the
# migration. Two levels:
#   (no argument)  park it: zero pods, data volume kept - rollback still possible
#   --delete       remove the Helm release AND its data volume - no way back
# upgrade-all.sh does not call this script; decide yourself when you are sure.
# Usage: ./scripts/upgrade/41-postgres-retire-old.sh [--delete]
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# The old release, remembered by 40-postgres-migrate.sh.
old="${POSTGRES_PREVIOUS_RELEASE:-}"
# Nothing to retire.
if [[ -z "${old}" ]]; then ok "there is no old PostgreSQL release"; exit 0; fi

# Park or delete?
if [[ "${1:-}" != "--delete" ]]; then
  # Announce the step.
  step "Park ${old}: zero pods, data volume kept"
  # Scale the StatefulSet to zero through Helm.
  deploy_postgres "${POSTGRES_PREVIOUS_VERSION}" 0
  # The claim "data-<release>-0" is still there.
  run kubectl --namespace postgres get persistentvolumeclaims
  # Explain what is still possible.
  info "rollback-postgres.sh can still bring ${old} back. To remove it for good: 41-postgres-retire-old.sh --delete"
else
  # Ask before destroying data.
  confirm "Delete PostgreSQL release ${old} AND its data volume? After this there is no way back to it." || fail "stopped by user"
  # Announce the step.
  step "Uninstall Helm release ${old}"
  # Removes the StatefulSet and its headless Service. Helm never deletes the
  # volume claim of a StatefulSet.
  helm_remove "${old}" postgres
  # Announce the step.
  step "Delete the data volume of ${old}"
  # The claim is deleted here. (The StorageClass keeps the files on the NFS
  # disk - "Retain" - until the volume object is deleted too.)
  run kubectl --namespace postgres delete persistentvolumeclaim "data-${old}-0" --ignore-not-found
  # Forget the old release.
  state_set POSTGRES_PREVIOUS_RELEASE ""
  # And its version.
  state_set POSTGRES_PREVIOUS_VERSION ""
fi
