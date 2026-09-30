#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GITEA_USER="${GITEA_USER:-gitea_admin}"
GITEA_PASS="${GITEA_PASS:-LabPass123!}"
REPO_URL="http://gitea.gitea.svc.cluster.local:3000/${GITEA_USER}/demo-gitops.git"

if command -v argocd >/dev/null; then
  echo "== argocd repo add =="
  argocd repo add "${REPO_URL}" \
    --username "${GITEA_USER}" \
    --password "${GITEA_PASS}" \
    --insecure-skip-server-verification \
    --upsert || true
else
  echo "argocd CLI not found; applying repository Secret instead."
  kubectl -n argocd create secret generic gitea-demo-gitops \
    --from-literal=type=git \
    --from-literal=url="${REPO_URL}" \
    --from-literal=username="${GITEA_USER}" \
    --from-literal=password="${GITEA_PASS}" \
    --from-literal=insecure=true \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n argocd label secret gitea-demo-gitops \
    argocd.argoproj.io/secret-type=repository --overwrite
fi

kubectl apply -f "${ROOT}/gitops/argocd/application.yaml"

echo
echo "Application demo-app created."
echo "  kubectl -n argocd get application"
echo "Seed image first if the pod is ImagePullBackOff: ./scripts/seed-image.sh"
