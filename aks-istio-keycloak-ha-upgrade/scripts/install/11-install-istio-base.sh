#!/usr/bin/env bash
# =============================================================================
# 11-install-istio-base.sh — install the Istio "base" chart (OLD version).
# It contains the CustomResourceDefinitions (the Istio object types such as
# Gateway and VirtualService) and is shared by all Istio revisions.
# Usage: ./scripts/install/11-install-istio-base.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster

# Announce the step.
step "Check that Istio ${ISTIO_VERSION_OLD} supports this Kubernetes version"
# Every Istio release supports only a window of Kubernetes versions.
check_istio_k8s "${ISTIO_VERSION_OLD}" "$(k8s_server_minor)"

# Announce the step.
step "Install the Istio base chart ${ISTIO_VERSION_OLD}"
# The second argument names the revision whose istiod validates Istio objects.
deploy_istio_base "${ISTIO_VERSION_OLD}" "$(istio_rev "${ISTIO_VERSION_OLD}")"

# Announce the step.
step "Show the Istio object types that now exist"
# Each line is one CustomResourceDefinition of Istio.
run kubectl get customresourcedefinitions --selector app.kubernetes.io/part-of=istio --output name
