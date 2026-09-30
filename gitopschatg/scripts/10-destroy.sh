#!/usr/bin/env bash
set -Eeuo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-gitops-lab}"
REG_NAME="${REG_NAME:-kind-registry}"

kind delete cluster --name "$CLUSTER_NAME" || true
docker rm -f "$REG_NAME" >/dev/null 2>&1 || true

echo "Removed Kind cluster $CLUSTER_NAME and registry $REG_NAME."
