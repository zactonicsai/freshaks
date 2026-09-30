#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-gitops-lab}"
REG_NAME="${REG_NAME:-kind-registry}"
REG_PORT="${REG_PORT:-5001}"

if [[ "$(docker inspect -f '{{.State.Running}}' "$REG_NAME" 2>/dev/null || true)" != "true" ]]; then
  docker rm -f "$REG_NAME" >/dev/null 2>&1 || true
  docker run -d --restart=always \
    -p "127.0.0.1:${REG_PORT}:5000" \
    --name "$REG_NAME" \
    registry:3 >/dev/null
  echo "Started registry $REG_NAME on localhost:$REG_PORT"
else
  echo "Registry $REG_NAME is already running."
fi

if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "Kind cluster $CLUSTER_NAME already exists."
else
  kind create cluster --name "$CLUSTER_NAME" --config "$ROOT_DIR/kind/kind-config.yaml"
fi

# Connect registry to the Kind Docker network.
if [[ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "$REG_NAME" 2>/dev/null || true)" == "null" ]]; then
  docker network connect kind "$REG_NAME"
fi

# Tell containerd on every Kind node that localhost:5001 maps to kind-registry:5000.
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
  docker exec "$node" mkdir -p "$REGISTRY_DIR"
  cat <<EOF | docker exec -i "$node" cp /dev/stdin "$REGISTRY_DIR/hosts.toml"
[host."http://${REG_NAME}:5000"]
EOF
done

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

kubectl get nodes -o wide
curl -fsS "http://localhost:${REG_PORT}/v2/" >/dev/null
echo "Kind cluster and registry are ready."
