#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kubectl apply -f "$ROOT_DIR/argocd/application.yaml"
kubectl -n argocd get application demo-app

echo "Argo CD Application created."
echo "The first sync may wait for Jenkins to create the first real image tag."
