#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITEA_USER="${GITEA_USER:-gitadmin}"
GITEA_PASSWORD="${GITEA_PASSWORD:-gitadmin123}"

helm repo add jenkins https://charts.jenkins.io --force-update
helm repo update jenkins
helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins \
  --create-namespace \
  -f "$ROOT_DIR/jenkins/values.yaml" \
  --wait \
  --timeout 15m

kubectl -n jenkins create secret generic gitea-credentials \
  --from-literal=username="$GITEA_USER" \
  --from-literal=password="$GITEA_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$ROOT_DIR/jenkins/terraform-readonly-rbac.yaml"

kubectl -n jenkins get pods
echo "Jenkins ready."
echo "Access: kubectl -n jenkins port-forward svc/jenkins 8081:8080"
echo "Login: admin / jenkins123"
