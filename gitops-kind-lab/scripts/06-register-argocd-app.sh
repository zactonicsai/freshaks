#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BB_PROJECT="${BB_PROJECT:-DEMO}"
REPO_URL="http://bitbucket.scm.svc.cluster.local:7990/scm/${BB_PROJECT}/demo-gitops.git"

if [[ -n "${BB_USER:-}" && -n "${BB_PASS:-}" ]] && command -v argocd >/dev/null; then
  echo "== argocd repo add =="
  argocd repo add "${REPO_URL}" \
    --username "${BB_USER}" \
    --password "${BB_PASS}" \
    --insecure-skip-server-verification \
    --upsert || true
else
  echo "Skipping CLI repo add."
  echo "Either export BB_USER and BB_PASS and install argocd CLI,"
  echo "or apply gitops/argocd/repo-secret.yaml.example after filling the token."
fi

TMP="$(mktemp)"
sed "s#/scm/DEMO/demo-gitops.git#/scm/${BB_PROJECT}/demo-gitops.git#" \
  "${ROOT}/gitops/argocd/application.yaml" > "${TMP}"
kubectl apply -f "${TMP}"
rm -f "${TMP}"

echo
echo "Application demo-app created."
echo "  kubectl -n argocd get application"
echo "  argocd app get demo-app"
echo "First sync will stay ImagePullBackOff until Jenkins (or seed-image.sh) publishes localhost:5001/demo-app:init"
