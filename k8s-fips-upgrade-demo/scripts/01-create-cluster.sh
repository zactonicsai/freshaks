#!/usr/bin/env bash
# 01-create-cluster.sh - makes the kind cluster: 1 control plane, 1 blue worker, 1 green worker.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init create-cluster "$@"
need docker kind kubectl
step "Create kind cluster '$CLUSTER_NAME' (Kubernetes from $KIND_NODE_IMAGE)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "cluster exists already, keeping it"
else
  render "$ROOT_DIR/k8s/kind-cluster.yaml" "NODEPORT_HTTPS=$NODEPORT_HTTPS" "HOST_HTTPS_PORT=$HOST_HTTPS_PORT" \
    "BLUE_KEY=$(sel_key "$BLUE_NODE_SELECTOR")" "BLUE_VALUE=$(sel_val "$BLUE_NODE_SELECTOR")" \
    "GREEN_KEY=$(sel_key "$GREEN_NODE_SELECTOR")" "GREEN_VALUE=$(sel_val "$GREEN_NODE_SELECTOR")" > "$WORK_DIR/kind-cluster.yaml"
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --config "$WORK_DIR/kind-cluster.yaml" --wait 180s
fi
k wait --for=condition=Ready nodes --all --timeout=180s
step "Write down, per node, whether its kernel is in FIPS mode"
label_nodes_with_fips_flag
k get nodes -L "$(sel_key "$BLUE_NODE_SELECTOR")" -L fipsdemo.test/kernel-fips
