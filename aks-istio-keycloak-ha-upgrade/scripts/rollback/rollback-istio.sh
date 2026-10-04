#!/usr/bin/env bash
# =============================================================================
# rollback-istio.sh — move the mesh back to the previous Istio version.
# Because of the revision tag this is the upgrade in reverse: make sure the
# old istiod runs, point the tag back at it, restart workloads and gateways.
# Before step 17 the old istiod is still installed, so this takes minutes.
# After step 17 the script installs the old version again first.
# The CRDs (base chart) are NOT downgraded: newer CRDs work with older istiod,
# and downgrading CRDs can delete fields of existing objects.
# Usage: ./scripts/rollback/rollback-istio.sh [VERSION]
#        Default: the version recorded by 13-istio-switch-tag.sh
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
# The active PostgreSQL release is needed for the workload restart.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/19-install-postgres.sh"

# Version to go back to: first argument, or the recorded previous version.
previous="${1:-${ISTIO_PREVIOUS_VERSION:-}}"
# Without a version we cannot continue.
[[ -n "${previous}" ]] || fail "No previous Istio version is recorded. Name it: rollback-istio.sh <version>"
# The version we are leaving.
current="${ISTIO_ACTIVE_VERSION}"
# Nothing to do when both are the same.
if [[ "${previous}" == "${current}" ]]; then ok "Istio ${current} is already the active version"; exit 0; fi

# Ask before changing anything.
confirm "Roll Istio back from ${current} to ${previous}?" || fail "stopped by user"

# Announce the step.
step "Check that Istio ${previous} supports this Kubernetes version"
# After a Kubernetes upgrade an old Istio version may no longer be supported.
check_istio_k8s "${previous}" "$(k8s_server_minor)"

# Announce the step.
step "Make sure istiod ${previous} is installed"
# Changes nothing when the release still exists; installs it again otherwise.
deploy_istiod "${previous}"

# Announce the step.
step "Let istiod ${previous} validate Istio objects again"
# The base chart stays on the newer version (CRDs are never downgraded); only
# its defaultRevision moves back.
deploy_istio_base "${current}" "$(istio_rev "${previous}")"

# Announce the step.
step "Move tag '${ISTIO_TAG}' back to ${previous}"
# New pods get the old sidecar again.
set_revision_tag "${previous}"
# The old version is the active one again.
state_set ISTIO_ACTIVE_VERSION "${previous}"
# Nothing to go back to any more.
state_set ISTIO_PREVIOUS_VERSION ""
# The newer control plane stays installed, unused, like a canary.
state_set ISTIO_CANARY_VERSION "${current}"

# Announce the step.
step "Restart the workloads so they get the ${previous} sidecar"
# PostgreSQL, Keycloak and the applications, one after the other.
restart_mesh_workloads

# Announce the step.
step "Put the gateways back on ${previous}"
# Gateway charts of the old version.
deploy_ingress_gateway "${previous}"
# Same for the egress gateway.
deploy_egress_gateway "${previous}"
# Replace the gateway pods so they get the old proxy.
restart_gateways

# Announce the step.
step "Check proxies and services"
# Every proxy must run the old version again; then the smoke test.
bash "${ROOT_DIR}/scripts/upgrade/16-istio-verify.sh"
# Explain the state.
info "istiod ${current} is still installed but unused. Remove it with: helm uninstall istiod-$(istio_rev "${current}") --namespace istio-system - or try the switch again with scripts/upgrade/13-istio-switch-tag.sh ${current}"
