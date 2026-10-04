#!/usr/bin/env bash
# =============================================================================
# 04-delete-istio.sh — remove Istio completely: routing and policy objects,
# both gateways, the revision tag, every control plane, the base chart and
# finally the CRDs.
# Usage: ./scripts/destroy/04-delete-istio.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster
# Ask before deleting.
confirm "Remove Istio (gateways, control planes, CRDs) from the cluster?" || fail "stopped by user"

# Announce the step.
step "Delete routing, egress and policy objects"
# The same files that were applied at install time, now with "kubectl delete".
for manifest in destinationrules virtualservices gateway egress authorization-policies peer-authentication; do
  # render fills in the placeholders; --ignore-not-found makes a re-run safe.
  render "${ROOT_DIR}/k8s/istio/${manifest}.yaml" | kubectl delete --ignore-not-found -f -
done

# Announce the step.
step "Uninstall the gateways"
# Removing the ingress gateway also removes the Azure load balancer rule; the
# static public IP itself stays (it belongs to our resource group).
helm_remove istio-ingressgateway istio-ingress
# The egress gateway.
helm_remove istio-egressgateway istio-egress
# The TLS secret was created with kubectl.
run kubectl --namespace istio-ingress delete secret wildcard-tls --ignore-not-found

# Announce the step.
step "Delete the revision tag"
# The tag webhook and the tag Service were applied with kubectl.
run kubectl delete mutatingwebhookconfiguration "istio-revision-tag-${ISTIO_TAG}" --ignore-not-found
# The Service that belongs to the tag.
run kubectl --namespace istio-system delete service "istiod-revision-tag-${ISTIO_TAG}" --ignore-not-found

# Every release in istio-system whose name starts with "istiod-" is a control plane.
for release in $(helm list --namespace istio-system --short | grep '^istiod-' || true); do
  # Announce the step.
  step "Uninstall control plane ${release}"
  # Removes the Deployment, Service, webhooks and config maps of that revision.
  helm_remove "${release}" istio-system
done

# Announce the step.
step "Uninstall the base chart"
# Removes the default validator. Helm keeps the CRDs on purpose.
helm_remove istio-base istio-system

# Announce the step.
step "Delete the Istio CRDs"
# Deleting a CRD deletes every object of that type, so this comes last.
# xargs hands the names to one kubectl call; nothing happens when there are none.
kubectl get customresourcedefinitions --output name | grep 'istio\.io' | xargs -r kubectl delete || true

# Forget the Istio facts.
for key in ISTIO_ACTIVE_VERSION ISTIO_PREVIOUS_VERSION ISTIO_CANARY_VERSION ISTIO_TARGET_VERSION; do
  # An empty value means "not known".
  state_set "${key}" ""
done
