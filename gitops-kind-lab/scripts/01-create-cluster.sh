#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REG_NAME="kind-registry"
REG_PORT="5001"
CLUSTER="gitops"

echo "== local registry =="
if [[ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != "true" ]]; then
  docker run -d --restart=always \
    --name "${REG_NAME}" \
    -p "127.0.0.1:${REG_PORT}:5000" \
    --network bridge \
    registry:2
else
  echo "registry already running"
fi

echo "== kind cluster =="
if kind get clusters | grep -qx "${CLUSTER}"; then
  echo "cluster ${CLUSTER} already exists"
else
  kind create cluster --config "${ROOT}/kind/cluster-config.yaml"
fi

echo "== containerd hosts.toml for localhost:${REG_PORT} =="
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name "${CLUSTER}"); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${REG_NAME}:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
done

echo "== attach registry to kind network =="
if [[ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REG_NAME}")" == "null" ]]; then
  docker network connect "kind" "${REG_NAME}"
fi

kubectl apply -f "${ROOT}/k8s/namespaces.yaml"
kubectl apply -f "${ROOT}/k8s/local-registry-cm.yaml"

echo
echo "Cluster ready."
echo "  kubectl get nodes"
echo "  registry: localhost:${REG_PORT}  (from host)"
echo "            ${REG_NAME}:5000     (from pods)"
