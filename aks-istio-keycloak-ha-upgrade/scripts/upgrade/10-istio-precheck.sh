#!/usr/bin/env bash
# =============================================================================
# 10-istio-precheck.sh — check that the next Istio hop is safe, and remember
# its version for the following steps (11 to 17).
# Rules checked: one minor version at a time, the target must support the
# cluster's Kubernetes version, and the previous hop must be finished.
# Usage: ./scripts/upgrade/10-istio-precheck.sh [TARGET_VERSION]
#        Default target: the next entry of ISTIO_UPGRADE_PATH (config/versions.env).
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

# Target: first argument, or the next version on the upgrade path.
target="${1:-$(next_version "${ISTIO_ACTIVE_VERSION}" "${ISTIO_UPGRADE_PATH}")}"
# Nothing newer on the path: there is nothing to do.
if [[ -z "${target}" ]]; then ok "Istio ${ISTIO_ACTIVE_VERSION} is already the newest version on the upgrade path"; exit 0; fi

# Announce the step.
step "Check the size of the hop: ${ISTIO_ACTIVE_VERSION} -> ${target}"
# Minor number of the running version: 1.28.1 -> 28
active_minor="$(minor_of "${ISTIO_ACTIVE_VERSION}" | cut -d. -f2)"
# Minor number of the target: 1.29.8 -> 29
target_minor="$(minor_of "${target}" | cut -d. -f2)"
# Going backwards is a rollback, not an upgrade.
if (( target_minor < active_minor )); then fail "${target} is older than ${ISTIO_ACTIVE_VERSION}. Use scripts/rollback/rollback-istio.sh to go back."; fi
# Istio supports upgrades across ONE minor version only.
if (( target_minor - active_minor > 1 )); then fail "Istio must be upgraded one minor version at a time. ${ISTIO_ACTIVE_VERSION} -> ${target} skips a version."; fi
# Report success.
ok "hop size is fine"

# Announce the step.
step "Check that Istio ${target} supports this Kubernetes version"
# Compares with the support table in scripts/lib/deploy.sh.
check_istio_k8s "${target}" "$(k8s_server_minor)"

# Announce the step.
step "Check that the previous hop is finished"
# During a hop two control planes run. Starting another hop on top of that
# would leave three, and no clear way back.
if [[ -n "${ISTIO_PREVIOUS_VERSION:-}" ]]; then fail "Istio ${ISTIO_PREVIOUS_VERSION} is still installed from the last hop. Run 17-istio-remove-old.sh (or rollback-istio.sh) first."; fi
# Report success.
ok "only one control plane is installed"

# Announce the step.
step "Get istioctl ${target} for the extra checks (optional)"
# Without internet access to GitHub this fails; the upgrade works without it.
bash "${ROOT_DIR}/scripts/tools/download-istioctl.sh" "${target}" || warn "istioctl could not be downloaded - continuing without it"

# Use istioctl when it is there.
if command -v istioctl >/dev/null 2>&1; then
  # Announce the step.
  step "Run Istio's own upgrade pre-check"
  # Looks for settings in the cluster that the new version no longer supports.
  run istioctl x precheck
  # Announce the step.
  step "Analyze the current Istio configuration"
  # Reports mistakes such as routes to Services that do not exist.
  run istioctl analyze --all-namespaces || warn "istioctl analyze reported findings - read them before you continue"
fi

# Remember the target for steps 11 to 17.
state_set ISTIO_TARGET_VERSION "${target}"
# Final message.
ok "ready to upgrade Istio ${ISTIO_ACTIVE_VERSION} -> ${target}"
