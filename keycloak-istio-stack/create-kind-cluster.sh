#!/usr/bin/env bash
# Create a NEW, local Kubernetes cluster on Docker Desktop with Istio installed.
# This is a separate, optional setup step. Existing chart and test scripts are unchanged.
#
# Prerequisites installed on the HOST (Mac/Linux/WSL): docker, kind, kubectl, istioctl.
#   kind:     https://kind.sigs.k8s.io/docs/user/quick-start/
#   istioctl: https://istio.io/latest/docs/setup/install/istioctl/
#
# Usage:
#   ./scripts/create-kind-cluster.sh
#   CLUSTER_NAME=my-keycloak-lab ./scripts/create-kind-cluster.sh
#
# After setup:
#   CONFIRM_CONTEXT=kind-keycloak-lab \
#     GATEWAY_REF=istio-system/local-keycloak-gateway \
#     ./scripts/test-docker-desktop.sh
#
# SAFETY:
# - Never deletes clusters or modifies a different kube-context.
# - Refuses to reuse an existing cluster unless REUSE_CLUSTER=true is explicit.
# - Never overwrites an existing Gateway resource or an existing Istio control plane.
# - Istio's "demo" profile is for a LOCAL LAB; not a production security baseline.
set -euo pipefail

SCRIPT_DIR="."
PROJECT_DIR="."
GATEWAY_MANIFEST="$PROJECT_DIR/examples/gateway-local.yaml"

CLUSTER_NAME="${CLUSTER_NAME:-keycloak-lab}"
CONTEXT="kind-$CLUSTER_NAME"
REUSE_CLUSTER="${REUSE_CLUSTER:-false}"
ISTIO_NAMESPACE=istio-system
GATEWAY_NAME=local-keycloak-gateway
INGRESS_SERVICE=istio-ingressgateway

die() {
  echo "ERROR: $*" >&2
  exit 1
}

step() {
  printf '\n[setup] %s\n' "$*"
}

# 1. Fail early with a useful message if prerequisites are missing.
for binary in docker kind kubectl istioctl; do
  command -v "$binary" >/dev/null 2>&1 || die "Missing '$binary'; install it before running this script."
done
[[ "$CLUSTER_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
  || die "CLUSTER_NAME must be lowercase letters, numbers, and hyphens."
[[ -r "$GATEWAY_MANIFEST" ]] || die "Missing existing Gateway example: $GATEWAY_MANIFEST"

step "Checking Docker Desktop / Docker Engine"
docker info >/dev/null 2>&1 || die "Docker is not running or the current user cannot access it."

# 2. Kind stands for Kubernetes IN Docker. Its default single control-plane
#    node is sufficient for this lab. No extraPortMappings are required because
#    the EXISTING test script uses kubectl port-forward to host port 18080.
step "Checking local kind cluster name: $CLUSTER_NAME"
if kind get clusters | grep -Fx "$CLUSTER_NAME" >/dev/null; then
  if [[ "$REUSE_CLUSTER" != true ]]; then
    die "Cluster '$CLUSTER_NAME' already exists. Choose another name or explicitly set REUSE_CLUSTER=true."
  fi
  echo "Reusing existing kind cluster '$CLUSTER_NAME'; no nodes will be deleted."
else
  echo "Creating a new kind cluster '$CLUSTER_NAME' (Docker image downloads may be required)."
  kind create cluster --name "$CLUSTER_NAME" --wait 180s
fi

# 3. Every kubectl/istioctl call specifies the exact context so nothing is
#    accidentally installed into a different EKS/AKS/production cluster.
kubectl config get-contexts -o name | grep -Fx "$CONTEXT" >/dev/null \
  || die "Expected context '$CONTEXT' was not created by kind."

step "Waiting for cluster nodes to become Ready"
kubectl --context "$CONTEXT" wait --for=condition=Ready node --all --timeout=180s

# 4. Install Istio's evaluation profile. It supplies 'istiod' and the
#    'istio-ingressgateway' Service expected by test-docker-desktop.sh.
#    Existing Istio installs are NOT upgraded, because version compatibility
#    and upgrade strategy must be reviewed separately.
step "Checking Istio installation"
if kubectl --context "$CONTEXT" -n "$ISTIO_NAMESPACE" get deployment istiod >/dev/null 2>&1; then
  echo "Found istiod; leaving the existing control plane unchanged."
else
  echo "Installing Istio demo profile into $CONTEXT."
  istioctl install --context "$CONTEXT" --set profile=demo -y
fi

step "Waiting for Istio to be healthy"
kubectl --context "$CONTEXT" -n "$ISTIO_NAMESPACE" rollout status deployment/istiod --timeout=300s
kubectl --context "$CONTEXT" -n "$ISTIO_NAMESPACE" get deployment "$INGRESS_SERVICE" >/dev/null 2>&1 \
  || die "Istio ingress gateway Deployment is missing. Review the Istio profile; this script will not change an existing installation."
kubectl --context "$CONTEXT" -n "$ISTIO_NAMESPACE" rollout status "deployment/$INGRESS_SERVICE" --timeout=300s
kubectl --context "$CONTEXT" -n "$ISTIO_NAMESPACE" get service "$INGRESS_SERVICE" >/dev/null \
  || die "Istio ingress Service '$INGRESS_SERVICE' is missing."
kubectl --context "$CONTEXT" wait --for=condition=Established \
  crd/gateways.networking.istio.io --timeout=120s
kubectl --context "$CONTEXT" wait --for=condition=Established \
  crd/virtualservices.networking.istio.io --timeout=120s

# 5. A Gateway OBJECT tells Istio which HTTP Host it should accept. This file
#    already ships with the Keycloak Helm project, so the script reuses it.
#    The Helm chart creates a VirtualService that points to this object.
step "Configuring the local HTTP Gateway"
if kubectl --context "$CONTEXT" -n "$ISTIO_NAMESPACE" \
  get gateways.networking.istio.io "$GATEWAY_NAME" >/dev/null 2>&1; then
  echo "Gateway '$ISTIO_NAMESPACE/$GATEWAY_NAME' already exists; not overwriting it."
else
  kubectl --context "$CONTEXT" apply -f "$GATEWAY_MANIFEST"
fi

# 6. The application namespace is created now; the original test script can
#    also create it, so this remains safe to rerun. Sidecar injection is NOT
#    enabled here: the example routes via the Istio ingress gateway to an
#    ordinary Kubernetes Service. Production mesh policy requires more design.
step "Creating the application namespace when missing"
if ! kubectl --context "$CONTEXT" get namespace identity-demo >/dev/null 2>&1; then
  kubectl --context "$CONTEXT" create namespace identity-demo
else
  echo "Namespace 'identity-demo' already exists; leaving it unchanged."
fi

step "Summary"
kubectl --context "$CONTEXT" get nodes -o wide
kubectl --context "$CONTEXT" -n "$ISTIO_NAMESPACE" get \
  deployments/istiod "deployments/$INGRESS_SERVICE" "services/$INGRESS_SERVICE"
kubectl --context "$CONTEXT" -n "$ISTIO_NAMESPACE" get \
  gateways.networking.istio.io "$GATEWAY_NAME"

# The existing Helm test script deliberately checks the CURRENT kube-context,
# so switch only after successful setup and make this side effect explicit.
kubectl config use-context "$CONTEXT" >/dev/null

echo
echo "SUCCESS: local kind Kubernetes + Istio Gateway setup is ready."
echo "Cluster context: $CONTEXT"
echo "Current kubectl context was switched to this newly verified local cluster."
echo "Gateway:         $ISTIO_NAMESPACE/$GATEWAY_NAME"
echo "Next, from the project directory, run:"
echo "  CONFIRM_CONTEXT=$CONTEXT GATEWAY_REF=$ISTIO_NAMESPACE/$GATEWAY_NAME ./scripts/test-docker-desktop.sh"
echo
echo "The Helm test script will then install Keycloak/PostgreSQL and test OIDC via port-forward."
echo "This setup script never starts the browser port-forward or installs the Helm release."
