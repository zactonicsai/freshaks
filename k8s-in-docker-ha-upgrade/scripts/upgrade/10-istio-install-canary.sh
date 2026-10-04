#!/usr/bin/env bash
# =============================================================================
# 10-istio-install-canary.sh — first half of an Istio upgrade: install the
# NEW control plane NEXT TO the old one ("canary"). Nothing uses it yet, so
# this step cannot disturb running traffic.
#   1. checks: one minor version at a time, Kubernetes supported, last upgrade finished
#   2. upgrade the CRDs (base chart) - newer definitions still work with the old istiod
#   3. install istiod of the new version as a second Helm release
# Usage: ./scripts/upgrade/10-istio-install-canary.sh [VERSION]
#        (default: the next version on ISTIO_UPGRADE_PATH)
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
# Target: first argument, or the next version on the upgrade path.
target="${1:-$(next_version "${ISTIO_ACTIVE_VERSION}" "${ISTIO_UPGRADE_PATH}")}"
# Nothing newer on the path: done.
if [[ -z "${target}" ]]; then ok "Istio ${ISTIO_ACTIVE_VERSION} is already the newest version on the upgrade path"; exit 0; fi

# Announce the step.
step "Check the size of the hop: ${ISTIO_ACTIVE_VERSION} -> ${target}"
# Second number of the active version, e.g. 28.
active_minor="$(minor_of "${ISTIO_ACTIVE_VERSION}" | cut -d. -f2)"
# Second number of the target version, e.g. 29.
target_minor="$(minor_of "${target}" | cut -d. -f2)"
# Going back is the job of the rollback script.
if (( target_minor < active_minor )); then fail "${target} is older than ${ISTIO_ACTIVE_VERSION}. Use scripts/rollback/rollback-istio.sh to go back."; fi
# One minor version at a time.
if (( target_minor - active_minor > 1 )); then fail "Istio is upgraded one minor version at a time here. ${ISTIO_ACTIVE_VERSION} -> ${target} skips a version."; fi
# Report success.
ok "hop size is fine"

# Announce the step.
step "Check that Istio ${target} supports this Kubernetes version"
# Stops the script when the combination is not supported.
check_istio_k8s "${target}" "$(k8s_server_minor)"

# Announce the step.
step "Check that the previous upgrade is finished"
# An old control plane from the last hop must be removed (or rolled back to) first.
if [[ -n "${ISTIO_PREVIOUS_VERSION:-}" ]]; then fail "Istio ${ISTIO_PREVIOUS_VERSION} is still installed from the last hop. Run 12-istio-remove-old.sh (or rollback-istio.sh) first."; fi
# Report success.
ok "only one control plane is installed"
# Remember the target for the next script.
state_set ISTIO_TARGET_VERSION "${target}"

# Announce the step.
step "Upgrade the CRDs: base chart ${target}"
# Make sure Helm knows the Istio chart repository.
ensure_istio_repo
# The validation webhook keeps pointing at the OLD istiod for now.
deploy_istio_base "${target}" "$(istio_rev "${ISTIO_ACTIVE_VERSION}")"

# Announce the step.
step "Install istiod ${target} as revision $(istio_rev "${target}")"
# A second Helm release next to the old one.
deploy_istiod "${target}"
# Remember that a canary is installed.
state_set ISTIO_CANARY_VERSION "${target}"

# Announce the step.
step "Show both control planes"
# One Deployment per revision.
run kubectl --namespace istio-system get deployments --selector app=istiod --label-columns istio.io/rev
# And their pods.
run kubectl --namespace istio-system get pods --selector app=istiod --label-columns istio.io/rev
# Explain the state we are in.
info "istiod ${target} is running, but the tag '${ISTIO_TAG}' still points at ${ISTIO_ACTIVE_VERSION}. Nothing uses the new version yet. Next: 11-istio-switch.sh"
