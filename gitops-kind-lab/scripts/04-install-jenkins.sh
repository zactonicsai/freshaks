#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -

helm repo add jenkins https://charts.jenkins.io
helm repo update jenkins

helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins \
  --create-namespace \
  -f "${ROOT}/helm/jenkins-values.yaml" \
  --timeout 10m

echo
echo "Jenkins UI: http://localhost:8082"
echo "User: admin"
echo -n "Password: "
kubectl -n jenkins get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' 2>/dev/null | base64 -d || echo "(secret not ready yet — retry in a minute)"
echo
echo "Add credential ID gitea-http (Username with password): gitea_admin / LabPass123!"
echo "Pipeline SCM: http://gitea.gitea.svc.cluster.local:3000/gitea_admin/demo-app.git"
echo "Branch main, script path Jenkinsfile."
