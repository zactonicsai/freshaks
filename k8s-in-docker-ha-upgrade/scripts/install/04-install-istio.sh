#!/usr/bin/env bash
# =============================================================================
# 04-install-istio.sh — install Istio (old version) in four parts:
#   base     the CRDs: new object types such as VirtualService
#   istiod   the control plane, installed as a "revision" (1-28-1)
#   tag      the name "stable" that points at that revision
#   gateways the ingress gateway (way in) and the egress gateway (way out)
# Usage: ./scripts/install/04-install-istio.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# Install the old version unless an upgrade has already moved on.
version="${ISTIO_ACTIVE_VERSION:-${ISTIO_VERSION_OLD}}"

# Announce the step.
step "Check that Istio ${version} supports this Kubernetes version"
# Every Istio release supports only a window of Kubernetes versions.
check_istio_k8s "${version}" "$(k8s_server_minor)"
# Make sure Helm knows the Istio chart repository.
ensure_istio_repo

# Announce the step.
step "Install the base chart (CRDs)"
# defaultRevision names the istiod that validates Istio objects.
deploy_istio_base "${version}" "$(istio_rev "${version}")"

# Announce the step.
step "Install the control plane istiod as revision $(istio_rev "${version}")"
# Two pods, see helm/values/istiod.yaml.
deploy_istiod "${version}"
# Remember which version is active.
state_set ISTIO_ACTIVE_VERSION "${version}"

# Announce the step.
step "Point the revision tag '${ISTIO_TAG}' at this revision"
# Namespaces and gateways refer to the tag, never to a version. An upgrade
# later moves the tag instead of touching every namespace.
set_revision_tag "${version}"

# Announce the step.
step "Install the ingress and the egress gateway"
# Two pods each. The ingress gateway is reachable on port 30443 of every
# worker node; the edge container balances over these ports.
deploy_gateways "${version}"

# Announce the step.
step "Show what runs"
# Control plane pods with their revision label.
run kubectl --namespace istio-system get pods --label-columns istio.io/rev
# Gateway pods and the node port.
run kubectl --namespace istio-ingress get pods,services --output wide
# Egress gateway pods.
run kubectl --namespace istio-egress get pods --output wide
