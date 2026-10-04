#!/usr/bin/env bash
# =============================================================================
# 13-set-revision-tag.sh — create the revision tag (default name "stable") and
# point it at the installed istiod.
# Namespaces and gateways refer to the TAG, never to a version. An upgrade
# later only moves the tag; nothing else has to be re-labelled.
# Usage: ./scripts/install/13-set-revision-tag.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The control plane must be installed first.
require_state ISTIO_ACTIVE_VERSION "scripts/install/12-install-istiod.sh"

# Announce the step.
step "Point tag '${ISTIO_TAG}' at Istio ${ISTIO_ACTIVE_VERSION}"
# Creates (or updates) the tag webhook and the tag Service.
set_revision_tag "${ISTIO_ACTIVE_VERSION}"

# Announce the step.
step "Show all sidecar-injection webhooks"
# One per revision plus one per tag; the REV column shows where a tag points.
run kubectl get mutatingwebhookconfigurations --label-columns istio.io/rev,istio.io/tag
