#!/usr/bin/env bash
# =============================================================================
# 13-istio-switch-tag.sh — move the revision tag to the new istiod.
# From now on every NEW pod gets the new sidecar. Running pods keep the old
# sidecar until they are restarted (step 14), so this step itself does not
# touch any traffic. To undo it: scripts/rollback/rollback-istio.sh
# Usage: ./scripts/upgrade/13-istio-switch-tag.sh [TARGET_VERSION]
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
# Already switched (for example when the script is run twice): nothing to do.
if [[ "${ISTIO_ACTIVE_VERSION}" == "${target}" ]]; then ok "tag '${ISTIO_TAG}' already points at ${target}"; exit 0; fi

# Announce the step.
step "Check that the new control plane is installed and ready"
# The Deployment istiod-<revision> must exist and be rolled out.
wait_rollout istio-system "deployment/istiod-$(istio_rev "${target}")" 5m

# Announce the step.
step "Let the new istiod validate Istio objects"
# Moves the default validation webhook to the new revision. This must happen
# before the old istiod is removed, otherwise every "kubectl apply" of an
# Istio object would be rejected.
deploy_istio_base "${target}" "$(istio_rev "${target}")"

# Announce the step.
step "Move tag '${ISTIO_TAG}' from ${ISTIO_ACTIVE_VERSION} to ${target}"
# Re-applies the tag webhook so that it calls the new istiod.
set_revision_tag "${target}"

# Remember the old version: it is still installed and is the way back.
state_set ISTIO_PREVIOUS_VERSION "${ISTIO_ACTIVE_VERSION}"
# The new version is now the active one.
state_set ISTIO_ACTIVE_VERSION "${target}"
# The canary became the active control plane.
state_set ISTIO_CANARY_VERSION ""
# Explain the state.
info "new pods now get the ${target} sidecar; existing pods change when they are restarted (step 14)"
