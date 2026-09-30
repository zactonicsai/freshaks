#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Current context ==="
kubectl config current-context

echo
echo "=== Nodes ==="
kubectl get nodes

echo
echo "=== Gitea ==="
kubectl -n gitea get deploy,pod,svc 2>/dev/null || true

echo
echo "=== Argo CD ==="
kubectl -n argocd get application demo-app 2>/dev/null || true
kubectl -n argocd get pods 2>/dev/null || true

echo
echo "=== Jenkins ==="
kubectl -n jenkins get pod,svc 2>/dev/null || true

echo
echo "=== Demo app ==="
kubectl -n demo-app get deploy,pod,svc 2>/dev/null || true
if kubectl -n demo-app get deploy demo-app >/dev/null 2>&1; then
  echo -n "Running desired image: "
  kubectl -n demo-app get deploy demo-app -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
fi

echo
echo "=== Registry tags ==="
curl -fsS http://localhost:5001/v2/demo-app/tags/list 2>/dev/null || echo "No demo-app image yet."

echo
echo "=== Argo CD admin password ==="
if kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  encoded=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}')
  if printf '%s' "$encoded" | base64 --decode >/dev/null 2>&1; then
    printf '%s' "$encoded" | base64 --decode
  else
    printf '%s' "$encoded" | base64 -D
  fi
  echo
else
  echo "Initial admin secret not present (it may already have been removed)."
fi
