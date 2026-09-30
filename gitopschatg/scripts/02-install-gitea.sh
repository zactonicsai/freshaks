#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITEA_USER="${GITEA_USER:-gitadmin}"
GITEA_PASSWORD="${GITEA_PASSWORD:-gitadmin123}"
GITEA_EMAIL="${GITEA_EMAIL:-gitadmin@local.lab}"

kubectl apply -f "$ROOT_DIR/gitea/gitea.yaml"
kubectl -n gitea rollout status deployment/gitea --timeout=180s

if kubectl -n gitea exec deploy/gitea -- gitea admin user list 2>/dev/null | grep -q "$GITEA_USER"; then
  echo "Gitea user $GITEA_USER already exists."
else
  kubectl -n gitea exec deploy/gitea -- \
    gitea admin user create \
      --username "$GITEA_USER" \
      --password "$GITEA_PASSWORD" \
      --email "$GITEA_EMAIL" \
      --admin \
      --must-change-password=false
fi

echo "Gitea ready."
echo "Access: kubectl -n gitea port-forward svc/gitea 3000:3000"
echo "Login:  $GITEA_USER / $GITEA_PASSWORD"
