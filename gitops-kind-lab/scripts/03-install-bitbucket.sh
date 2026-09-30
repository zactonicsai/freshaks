#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

kubectl apply -f "${ROOT}/k8s/namespaces.yaml"
kubectl apply -f "${ROOT}/k8s/bitbucket.yaml"

echo "Waiting for Bitbucket pod (first image pull + JVM can take several minutes)..."
kubectl -n scm rollout status deploy/bitbucket --timeout=10m || true

echo
echo "Bitbucket UI: http://localhost:7990"
echo "Complete the setup wizard (Standalone, internal DB is fine for the lab)."
echo "Create project DEMO and repos demo-app + demo-gitops."
echo "Create an HTTP access token with repo read+write."
kubectl -n scm get pods,svc
