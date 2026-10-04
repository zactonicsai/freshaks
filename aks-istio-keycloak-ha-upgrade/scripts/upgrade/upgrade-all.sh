#!/usr/bin/env bash
# =============================================================================
# upgrade-all.sh — run the complete upgrade in the safe order (60 to 120 min):
#   1. checks and backups
#   2. Istio, one minor version at a time (while Kubernetes is still old,
#      because every Istio version supports only some Kubernetes versions)
#   3. Kubernetes, one minor version at a time (control plane, then nodes)
#   4. Keycloak (works with the old PostgreSQL)
#   5. PostgreSQL (new server next to the old one, copy, switch)
#   6. the two applications (rolling)
#   7. verification and the availability report
# The availability probe runs the whole time and shows what users noticed.
# Usage: ./scripts/upgrade/upgrade-all.sh
#        Unattended: ASSUME_YES=true ./scripts/upgrade/upgrade-all.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Ask once for the whole upgrade.
confirm "Upgrade everything (Istio -> ${ISTIO_UPGRADE_PATH##* }, Kubernetes -> ${K8S_UPGRADE_PATH##* }, Keycloak -> ${KEYCLOAK_VERSION_NEW}, PostgreSQL -> ${POSTGRES_VERSION_NEW}, apps -> ${APP_VERSION_NEW})?" || fail "stopped by user"
# The scripts started below must not ask again.
export ASSUME_YES=true

# --- 1. Checks and backups -------------------------------------------------------
# Find blockers before anything changes.
run_script upgrade/00-preflight-checks.sh
# Start measuring availability in the background.
run_script tools/availability-probe.sh start
# Dump the Keycloak database.
run_script upgrade/01-backup-postgres.sh
# Save Helm values, manifests and Istio configuration.
run_script upgrade/02-backup-cluster-state.sh

# --- 2. Istio ---------------------------------------------------------------------
# Canary upgrade, one minor version per round.
run_script upgrade/18-istio-upgrade-all-hops.sh

# --- 3. Kubernetes ----------------------------------------------------------------
# Control plane, node pools and smoke test, one minor version per round.
run_script upgrade/25-aks-upgrade-all-hops.sh

# --- 4. Keycloak ------------------------------------------------------------------
# Stop, back up, start the new version.
run_script upgrade/30-keycloak-upgrade.sh

# --- 5. PostgreSQL ----------------------------------------------------------------
# New server next to the old one.
run_script upgrade/40-postgres-install-new.sh
# Read the state again: step 40 tells us whether a data migration is needed.
state_reload
# Only a major version change needs the copy and the switch.
if [[ -n "${POSTGRES_CANDIDATE_RELEASE:-}" ]]; then
  # Copy the data.
  run_script upgrade/41-postgres-migrate-data.sh
  # Switch the Service and start Keycloak.
  run_script upgrade/42-postgres-switch.sh
fi

# --- 6. Applications --------------------------------------------------------------
# Build and push the new images.
run_script install/21-build-push-images.sh "${APP_VERSION_NEW}"
# Rolling upgrade.
run_script upgrade/50-apps-upgrade.sh "${APP_VERSION_NEW}"

# --- 7. Verification --------------------------------------------------------------
# Versions, smoke test, login test.
run_script upgrade/60-post-upgrade-verify.sh
# Stop measuring.
run_script tools/availability-probe.sh stop
# Print availability per service.
run_script tools/availability-probe.sh report

# The old PostgreSQL release is kept on purpose.
info "The old PostgreSQL release is still running as the way back. Park or delete it with scripts/upgrade/43-postgres-retire-old.sh when you are sure."
