#!/usr/bin/env bash
# =============================================================================
# 11-istio-upgrade-crds.sh — upgrade the Istio "base" chart (the CRDs) to the
# target version. CRDs are shared by all revisions and are backward compatible,
# so they are upgraded first; the running control plane is not touched.
# Usage: ./scripts/upgrade/11-istio-upgrade-crds.sh [TARGET_VERSION]
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
step "Upgrade the Istio base chart to ${target}"
# defaultRevision stays on the ACTIVE revision: the old istiod keeps
# validating Istio objects until the tag is switched in step 13.
deploy_istio_base "${target}" "$(istio_rev "${ISTIO_ACTIVE_VERSION}")"

# Announce the step.
step "Show the base release"
# CHART shows the new version.
run helm list --namespace istio-system
