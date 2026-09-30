#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  -f "${ROOT}/helm/argocd-values.yaml" \
  --wait \
  --timeout 10m

echo
echo "Argo CD UI: http://localhost:8081"
echo "User: admin"
echo -n "Password: "
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
