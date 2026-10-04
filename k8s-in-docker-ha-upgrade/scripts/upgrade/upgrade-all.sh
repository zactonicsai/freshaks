#!/usr/bin/env bash
# =============================================================================
# upgrade-all.sh — upgrade everything from the OLD to the NEW versions while
# the availability probe measures what users would notice (30 to 60 minutes).
# Order (and why):
#   1. Istio, one minor version per round   - every Istio release supports only
#                                             a window of Kubernetes versions
#   2. Kubernetes, one minor version per round: control plane, then each node
#   3. Keycloak                              - while the old database is still there
#   4. PostgreSQL                            - one change at a time
#   5. the applications                      - last, on a proven platform
# It skips whatever is already done, so it can be run again after a failure.
# To learn, run the numbered scripts yourself instead.
# Usage: ./scripts/upgrade/upgrade-all.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Ask once; the numbered scripts then run without further questions.
confirm "Upgrade everything now? Logins will pause a few times; see the README for what to expect." || fail "stopped by user"
# The scripts started below inherit this setting.
export ASSUME_YES=true

# Measure availability from here on.
run_script tools/availability-probe.sh start
# Health checks, database dump, snapshot of the configuration.
run_script upgrade/01-preflight-and-backup.sh

# --- 1. Istio: repeat until the newest version on the path is active ---------
while true; do
  # Pick up the versions the last script recorded.
  state_reload
  # The next Istio version, or nothing when we are at the end of the path.
  next_istio="$(next_version "${ISTIO_ACTIVE_VERSION}" "${ISTIO_UPGRADE_PATH}")"
  # Leave the loop when there is nothing left to do.
  if [[ -z "${next_istio}" ]]; then break; fi
  # New control plane next to the old one.
  run_script upgrade/10-istio-install-canary.sh "${next_istio}"
  # Move tag, workloads and gateways; verify.
  run_script upgrade/11-istio-switch.sh "${next_istio}"
  # Remove the old control plane.
  run_script upgrade/12-istio-remove-old.sh
done

# --- 2. Kubernetes: repeat until the newest version on the path runs ---------
while true; do
  # Pick up the versions the last script recorded.
  state_reload
  # The next Kubernetes version, or nothing when we are at the end of the path.
  next_k8s="$(next_version "${K8S_SERVER_VERSION}" "${K8S_UPGRADE_PATH}")"
  # Control plane first (a no-op when it is already on the newest version).
  if [[ -n "${next_k8s}" ]]; then run_script upgrade/20-k8s-upgrade-control-plane.sh "${next_k8s}"; fi
  # Then every worker node, one at a time (each call is a no-op for a node
  # that already runs the control plane's version).
  for node in "${AGENT_LIST[@]}"; do
    # Cordon, drain, replace, uncordon.
    run_script upgrade/21-k8s-upgrade-node.sh "${node}"
  done
  # Leave the loop when the control plane was already on the newest version.
  if [[ -z "${next_k8s}" ]]; then break; fi
done

# --- 3. Keycloak ---------------------------------------------------------------
# Stop, back up, start the new version.
run_script upgrade/30-keycloak-upgrade.sh

# --- 4. PostgreSQL ---------------------------------------------------------------
# New server, copy, switch. The old server keeps running as the way back.
run_script upgrade/40-postgres-migrate.sh

# --- 5. Applications --------------------------------------------------------------
# Build and push the new image.
run_script install/08-build-image.sh "${APP_VERSION_NEW}"
# Rolling update of both applications.
run_script upgrade/50-apps-upgrade.sh "${APP_VERSION_NEW}"

# --- Check and report ---------------------------------------------------------------
# Versions, smoke test, login test.
run_script upgrade/60-verify.sh
# Stop measuring.
run_script tools/availability-probe.sh stop
# Availability per service and the longest outage.
run_script tools/availability-probe.sh report
# Final message.
ok "upgrade finished. The old PostgreSQL server still runs as the way back; retire it with scripts/upgrade/41-postgres-retire-old.sh"
