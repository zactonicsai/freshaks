#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  -f "$ROOT_DIR/argocd/values.yaml" \
  --wait \
  --timeout 10m

kubectl -n argocd get pods
echo "Argo CD ready."
echo "Access: kubectl -n argocd port-forward svc/argocd-server 8080:80"
