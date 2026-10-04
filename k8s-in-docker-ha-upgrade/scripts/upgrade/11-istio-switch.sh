#!/usr/bin/env bash
# =============================================================================
# 11-istio-switch.sh — second half of an Istio upgrade: move everything to
# the new control plane.
#   1. the new istiod takes over the validation of Istio objects
#   2. the revision tag "stable" is moved to the new revision
#      (moving the tag changes NO running pod - it decides what NEW pods get)
#   3. PostgreSQL, Keycloak and the apps are restarted, one after the other,
#      and come back with the new sidecar
#   4. the gateways are upgraded
#   5. every proxy is checked, then the smoke test runs
# The old control plane stays installed, so rollback-istio.sh is quick.
# Usage: ./scripts/upgrade/11-istio-switch.sh [VERSION]
#        (default: the version installed by 10-istio-install-canary.sh)
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
# Target: first argument, or the canary installed by script 10.
target="${1:-${ISTIO_CANARY_VERSION:-}}"
# Without a canary there is nothing to switch to.
[[ -n "${target}" ]] || fail "No new control plane is installed. Run scripts/upgrade/10-istio-install-canary.sh first."
# Already there: done.
if [[ "${ISTIO_ACTIVE_VERSION}" == "${target}" ]]; then ok "tag '${ISTIO_TAG}' already points at ${target}"; exit 0; fi

# Announce the step.
step "Check that the new control plane is installed and ready"
# Fails when the Deployment does not exist or is not ready.
wait_rollout istio-system "deployment/istiod-$(istio_rev "${target}")" 5m

# Announce the step.
step "Let the new istiod validate Istio objects"
# Make sure Helm knows the Istio chart repository.
ensure_istio_repo
# defaultRevision moves to the new revision. This must happen before the old
# istiod is ever removed, or every "kubectl apply" of an Istio object would fail.
deploy_istio_base "${target}" "$(istio_rev "${target}")"

# Announce the step.
step "Move tag '${ISTIO_TAG}' from ${ISTIO_ACTIVE_VERSION} to ${target}"
# From now on new pods get the sidecar of the new version.
set_revision_tag "${target}"
# Remember the old version as the way back ...
state_set ISTIO_PREVIOUS_VERSION "${ISTIO_ACTIVE_VERSION}"
# ... and the new one as active.
state_set ISTIO_ACTIVE_VERSION "${target}"
# The canary is no longer "just installed".
state_set ISTIO_CANARY_VERSION ""

# Announce the step.
step "Restart PostgreSQL, Keycloak and the applications, one after the other"
# Two-pod workloads are replaced without a gap; the single database pod is
# away for some seconds (logins pause, signed-in users keep working).
restart_mesh_workloads

# Announce the step.
step "Upgrade the gateways to ${target}"
# New chart version; the pods are replaced one by one.
deploy_gateways "${target}"
# If the chart did not change the pods, they still run the old proxy: restart them.
if mesh_proxy_report | awk -v wanted=":${target}" '($1 == "istio-ingress" || $1 == "istio-egress") && index($3, wanted) == 0 { found = 1 } END { exit found ? 0 : 1 }'; then restart_gateways; else ok "all gateway pods already run proxy ${target}"; fi

# Announce the step.
step "Every proxy must run version ${target}"
# Retries for up to 3 minutes while old pods finish shutting down.
wait_proxy_versions "${target}"

# Announce the step.
step "The services must still answer through the upgraded mesh"
# Public endpoints and access rules.
bash "${ROOT_DIR}/scripts/install/10-smoke-test.sh"
# Explain what is left to do.
info "Istio ${ISTIO_PREVIOUS_VERSION} is still installed as the way back (rollback-istio.sh). When you are sure: 12-istio-remove-old.sh"
