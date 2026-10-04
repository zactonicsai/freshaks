#!/usr/bin/env bash
# =============================================================================
# 43-postgres-retire-old.sh — retire the OLD PostgreSQL after the switch.
# Default: "park" it - scale it to zero pods but keep its data volume, so a
# rollback is still possible and costs nothing but disk space.
# With --delete: uninstall it and delete its data volume for good.
# upgrade-all.sh does NOT run this script; decide yourself when the time has come.
# Usage: ./scripts/upgrade/43-postgres-retire-old.sh [--delete]
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The old release (empty when there is none).
old="${POSTGRES_PREVIOUS_RELEASE:-}"
# Nothing to retire.
if [[ -z "${old}" ]]; then ok "there is no old PostgreSQL release"; exit 0; fi

# Two modes: park (default) or delete.
if [[ "${1:-}" != "--delete" ]]; then
  # Announce the step.
  step "Park ${old}: zero pods, data volume kept"
  # Second argument 0 = no pods. The PersistentVolumeClaim stays.
  deploy_postgres "${POSTGRES_PREVIOUS_VERSION}" 0
  # Show that the volume is still there.
  run kubectl --namespace postgres get persistentvolumeclaims
  # Explain the state.
  info "rollback-postgres.sh can still bring ${old} back. To remove it for good: 43-postgres-retire-old.sh --delete"
else
  # Ask before destroying data.
  confirm "Delete PostgreSQL release ${old} AND its data volume? After this there is no way back to it." || fail "stopped by user"
  # Announce the step.
  step "Uninstall Helm release ${old}"
  # Removes the StatefulSet, the headless Service and the ConfigMap.
  helm_remove "${old}" postgres
  # Announce the step.
  step "Delete the data volume of ${old}"
  # Helm never deletes volumes of a StatefulSet; do it by hand. The claim is
  # named <template>-<statefulset>-<index>.
  run kubectl --namespace postgres delete persistentvolumeclaim "data-${old}-0" --ignore-not-found
  # Forget the old release.
  state_set POSTGRES_PREVIOUS_RELEASE ""
  # Forget its version.
  state_set POSTGRES_PREVIOUS_VERSION ""
fi
