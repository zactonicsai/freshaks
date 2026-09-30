#!/usr/bin/env bash
set -euo pipefail
CLUSTER="${CLUSTER:-gitops}"

echo "Deleting Kind cluster ${CLUSTER}..."
kind delete cluster --name "${CLUSTER}" || true

echo "Removing local registry container..."
docker rm -f kind-registry >/dev/null 2>&1 || true

echo "Done."
