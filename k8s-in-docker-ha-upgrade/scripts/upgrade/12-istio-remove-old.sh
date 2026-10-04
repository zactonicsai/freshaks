#!/usr/bin/env bash
# =============================================================================
# 12-istio-remove-old.sh — last step of an Istio upgrade: uninstall the old
# control plane. Until now going back took one command; after this script the
# old version would have to be installed again first. Run it only when you
# are sure about the new version.
# Usage: ./scripts/upgrade/12-istio-remove-old.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# The old version, remembered by 11-istio-switch.sh.
previous="${ISTIO_PREVIOUS_VERSION:-}"
# Nothing to remove.
if [[ -z "${previous}" ]]; then ok "no old Istio control plane is installed"; exit 0; fi

# Announce the step.
step "Safety check: no pod may still use a proxy of ${previous}"
# grep -F searches for the plain text ":1.28.1" in the proxy image names.
if mesh_proxy_report | grep -F ":${previous}" >/dev/null; then fail "Some pods still run proxy ${previous}. Run 11-istio-switch.sh again first."; fi
# Report success.
ok "no pod uses ${previous} any more"
# Ask before closing the easy way back.
confirm "Remove the old control plane istiod ${previous}?" || fail "stopped by user"

# Announce the step.
step "Uninstall Helm release istiod-$(istio_rev "${previous}")"
# Removes the old Deployment, Service, webhook and configuration.
helm_remove "istiod-$(istio_rev "${previous}")" istio-system
# Forget the old version.
state_set ISTIO_PREVIOUS_VERSION ""

# Announce the step.
step "Show what is left"
# Only the new control plane remains.
run kubectl --namespace istio-system get deployments --selector app=istiod --label-columns istio.io/rev
