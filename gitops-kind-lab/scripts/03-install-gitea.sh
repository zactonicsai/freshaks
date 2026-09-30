#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GITEA_USER="${GITEA_USER:-gitea_admin}"
GITEA_PASS="${GITEA_PASS:-LabPass123!}"
GITEA_EMAIL="${GITEA_EMAIL:-gitea@lab.local}"

kubectl apply -f "${ROOT}/k8s/namespaces.yaml"
kubectl apply -f "${ROOT}/k8s/gitea.yaml"

echo "Waiting for Gitea..."
kubectl -n gitea rollout status deploy/gitea --timeout=8m

# Admin user (idempotent)
echo "Ensuring admin user ${GITEA_USER}..."
kubectl -n gitea exec deploy/gitea -- \
  gitea admin user create \
    --admin \
    --username "${GITEA_USER}" \
    --password "${GITEA_PASS}" \
    --email "${GITEA_EMAIL}" \
    --must-change-password=false \
  2>/dev/null || \
kubectl -n gitea exec deploy/gitea -- \
  gitea admin user change-password \
    --username "${GITEA_USER}" \
    --password "${GITEA_PASS}" \
    --must-change-password=false \
  2>/dev/null || true

# Repos via API (host NodePort)
API="http://127.0.0.1:3000"
echo "Waiting for Gitea API on ${API}..."
for i in $(seq 1 60); do
  if curl -sf "${API}/api/healthz" >/dev/null; then
    break
  fi
  sleep 2
done

create_repo() {
  local name="$1"
  curl -sf -u "${GITEA_USER}:${GITEA_PASS}" \
    -H "Content-Type: application/json" \
    -X POST "${API}/api/v1/user/repos" \
    -d "{\"name\":\"${name}\",\"private\":false,\"auto_init\":false,\"default_branch\":\"main\"}" \
    >/dev/null || echo "repo ${name} may already exist"
}

create_repo demo-app
create_repo demo-gitops

echo
echo "Gitea UI:      http://localhost:3000"
echo "User:          ${GITEA_USER}"
echo "Password:      ${GITEA_PASS}"
echo "Repos:         ${GITEA_USER}/demo-app  ${GITEA_USER}/demo-gitops"
echo "In-cluster:    http://gitea.gitea.svc.cluster.local:3000"
kubectl -n gitea get pods,svc
