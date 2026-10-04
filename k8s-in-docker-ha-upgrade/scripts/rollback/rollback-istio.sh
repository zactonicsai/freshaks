#!/usr/bin/env bash
# =============================================================================
# rollback-istio.sh — go back to the previous Istio version.
# Before 12-istio-remove-old.sh this is quick: the old control plane is still
# installed, so the tag is pointed back at it and the workloads are restarted.
# After script 12 the old control plane is installed again first (give the
# version as argument).
# The CRDs stay on the newer version on purpose: newer definitions work with
# the older control plane, and downgrading CRDs can damage existing objects.
# Usage: ./scripts/rollback/rollback-istio.sh [VERSION]
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# The active version must be known.
require_state ISTIO_ACTIVE_VERSION "scripts/install/04-install-istio.sh"
# The active database is restarted below.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/06-install-postgres.sh"
# Version to go back to: first argument, or the one remembered by 11-istio-switch.sh.
previous="${1:-${ISTIO_PREVIOUS_VERSION:-}}"
# Without a version there is nothing to go back to.
[[ -n "${previous}" ]] || fail "No previous Istio version is recorded. Name it: rollback-istio.sh <version>"
# The version that is active now.
current="${ISTIO_ACTIVE_VERSION}"
# Already there: done.
if [[ "${previous}" == "${current}" ]]; then ok "Istio ${current} is already the active version"; exit 0; fi
# Ask before changing anything.
confirm "Roll Istio back from ${current} to ${previous}?" || fail "stopped by user"

# Announce the step.
step "Check that Istio ${previous} supports this Kubernetes version"
# After a Kubernetes upgrade the old Istio version may no longer be allowed.
check_istio_k8s "${previous}" "$(k8s_server_minor)"

# Announce the step.
step "Make sure istiod ${previous} is installed"
# Make sure Helm knows the Istio chart repository.
ensure_istio_repo
# A no-op when the old control plane is still there; otherwise it is installed again.
deploy_istiod "${previous}"

# Announce the step.
step "Let istiod ${previous} validate Istio objects again"
# The base chart (CRDs) stays on the newer version; only defaultRevision moves.
deploy_istio_base "${current}" "$(istio_rev "${previous}")"

# Announce the step.
step "Move tag '${ISTIO_TAG}' back to ${previous}"
# New pods get the old sidecar again.
set_revision_tag "${previous}"
# The old version is active again.
state_set ISTIO_ACTIVE_VERSION "${previous}"
# Nothing to roll back to any more.
state_set ISTIO_PREVIOUS_VERSION ""
# The newer control plane stays installed, unused, like a canary.
state_set ISTIO_CANARY_VERSION "${current}"

# Announce the step.
step "Restart the workloads so they get the ${previous} sidecar"
# PostgreSQL, Keycloak, then the applications.
restart_mesh_workloads

# Announce the step.
step "Put the gateways back on ${previous}"
# Old chart version.
deploy_gateways "${previous}"
# Make sure the gateway pods are re-created with the old proxy.
restart_gateways

# Announce the step.
step "Check proxies and services"
# Every proxy must run the old version again.
wait_proxy_versions "${previous}"
# Public endpoints and access rules.
bash "${ROOT_DIR}/scripts/install/10-smoke-test.sh"
# Explain the state we are in.
info "istiod ${current} is still installed but unused. Try the switch again with scripts/upgrade/11-istio-switch.sh ${current}, or remove it: scripts/tools/in-tools.sh helm uninstall istiod-$(istio_rev "${current}") --namespace istio-system"
