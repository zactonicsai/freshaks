#!/usr/bin/env bash
# =============================================================================
# 17-istio-remove-old.sh — remove the OLD istiod after the new one has been
# verified. Until this step the way back is a single command
# (scripts/rollback/rollback-istio.sh); afterwards the rollback has to install
# the old version again first. Take your time before you run it.
# Usage: ./scripts/upgrade/17-istio-remove-old.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The old version that is still installed (empty when there is none).
previous="${ISTIO_PREVIOUS_VERSION:-}"
# Nothing to remove.
if [[ -z "${previous}" ]]; then ok "no old Istio control plane is installed"; exit 0; fi

# Announce the step.
step "Safety check: no pod may still use a proxy of ${previous}"
# grep -F looks for the literal text ":<old version>" in the proxy report.
if mesh_proxy_report | grep -F ":${previous}" >/dev/null; then fail "Some pods still run proxy ${previous}. Run steps 14 to 16 first."; fi
# Report success.
ok "no pod uses ${previous} any more"

# Ask before removing the easy way back.
confirm "Remove the old control plane istiod ${previous}?" || fail "stopped by user"

# Announce the step.
step "Uninstall Helm release istiod-$(istio_rev "${previous}")"
# Removes the old Deployment, Service, webhooks and config maps.
helm_remove "istiod-$(istio_rev "${previous}")" istio-system

# Forget the old version.
state_set ISTIO_PREVIOUS_VERSION ""

# Announce the step.
step "Show what is left"
# Only the new control plane should be listed.
run kubectl --namespace istio-system get deployments --selector app=istiod --label-columns istio.io/rev
