#!/usr/bin/env bash
# =============================================================================
# 18-istio-upgrade-all-hops.sh — walk Istio from the installed version to the
# newest one, one minor version at a time. Every hop runs steps 10 to 17.
# Usage: ./scripts/upgrade/18-istio-upgrade-all-hops.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The running Istio version must be known.
require_state ISTIO_ACTIVE_VERSION "scripts/install/12-install-istiod.sh"

# Ask once for the whole walk instead of once per hop.
confirm "Upgrade Istio ${ISTIO_ACTIVE_VERSION} along the path '${ISTIO_UPGRADE_PATH}' and remove each old version after it was verified?" || fail "stopped by user"
# The scripts started below must not ask again.
export ASSUME_YES=true

# One round per version on the path (split at the spaces on purpose).
for target in ${ISTIO_UPGRADE_PATH}; do
  # Read the state again: the previous round changed ISTIO_ACTIVE_VERSION.
  state_reload
  # Skip versions that are not newer than the running one.
  if [[ "$(next_version "${ISTIO_ACTIVE_VERSION}" "${target}")" != "${target}" ]]; then info "skipping ${target}: ${ISTIO_ACTIVE_VERSION} is already running"; continue; fi
  # Check the hop and remember the target.
  run_script upgrade/10-istio-precheck.sh "${target}"
  # Upgrade the CRDs.
  run_script upgrade/11-istio-upgrade-crds.sh "${target}"
  # Install the new control plane next to the old one.
  run_script upgrade/12-istio-install-canary.sh "${target}"
  # Point the tag at the new control plane.
  run_script upgrade/13-istio-switch-tag.sh "${target}"
  # Restart the workloads so they get the new sidecar.
  run_script upgrade/14-istio-restart-workloads.sh
  # Upgrade both gateways.
  run_script upgrade/15-istio-upgrade-gateways.sh
  # Check proxies and services.
  run_script upgrade/16-istio-verify.sh
  # Remove the old control plane.
  run_script upgrade/17-istio-remove-old.sh
done

# Read the final state.
state_reload
# Final message.
ok "Istio is now at ${ISTIO_ACTIVE_VERSION}"
