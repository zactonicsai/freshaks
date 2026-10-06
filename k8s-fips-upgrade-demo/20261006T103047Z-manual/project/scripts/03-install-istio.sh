#!/usr/bin/env bash
# 03-install-istio.sh - installs the Istio control plane (normal, non-FIPS settings) and the ingress gateway.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init install-istio "$@"
need kubectl istioctl
step "Install Istio $ISTIO_VERSION control plane"
mesh_install ""
step "Install the ingress gateway (NodePort $NODEPORT_HTTPS -> https://$APP_HOSTNAME:$HOST_HTTPS_PORT)"
gateway_install
step "Result"
istioctl --context "$KUBE_CONTEXT" version || true
k -n "$ISTIO_NS" get pods -o wide
k -n "$INGRESS_NS" get pods,svc -o wide
log "compliance policy on istiod right now: '$(mesh_policy_now)' (empty = normal Istio)"
