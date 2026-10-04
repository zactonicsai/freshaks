#!/usr/bin/env bash
# =============================================================================
# 12-istio-install-canary.sh — install the NEW istiod next to the old one.
# This is the "canary": it runs, but no pod uses it yet, so nothing can break.
# Usage: ./scripts/upgrade/12-istio-install-canary.sh [TARGET_VERSION]
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
# Target: first argument, or the version remembered by the pre-check.
target="${1:-${ISTIO_TARGET_VERSION:-}}"
# Without a target we cannot continue.
[[ -n "${target}" ]] || fail "No target version. Run scripts/upgrade/10-istio-precheck.sh first."

# Announce the step.
step "Install istiod ${target} as revision $(istio_rev "${target}")"
# A second Helm release; the old release "istiod-<old revision>" stays as it is.
deploy_istiod "${target}"

# Remember that a canary control plane exists.
state_set ISTIO_CANARY_VERSION "${target}"

# Announce the step.
step "Show both control planes"
# The REV column tells the two Deployments apart.
run kubectl --namespace istio-system get deployments --selector app=istiod --label-columns istio.io/rev
# Two pods per control plane.
run kubectl --namespace istio-system get pods --selector app=istiod --label-columns istio.io/rev
# Explain the state.
info "istiod ${target} is running, but the tag '${ISTIO_TAG}' still points at ${ISTIO_ACTIVE_VERSION}. Nothing uses the new version yet."
