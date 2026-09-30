#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${JENKINS_FORWARD_PORT:-18081}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASSWORD="${JENKINS_PASSWORD:-jenkins123}"
TMP="$(mktemp -d)"
PF_PID=""
cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

kubectl -n jenkins port-forward svc/jenkins "${PORT}:8080" >"$TMP/port-forward.log" 2>&1 &
PF_PID=$!
for _ in {1..60}; do
  if curl -fsS -u "$JENKINS_USER:$JENKINS_PASSWORD" "http://127.0.0.1:${PORT}/api/json" >/dev/null 2>&1; then break; fi
  sleep 1
done

crumb_json=$(curl -fsS -u "$JENKINS_USER:$JENKINS_PASSWORD" "http://127.0.0.1:${PORT}/crumbIssuer/api/json")
crumb_field=$(printf '%s' "$crumb_json" | sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p')
crumb=$(printf '%s' "$crumb_json" | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')

if curl -fsS -u "$JENKINS_USER:$JENKINS_PASSWORD" "http://127.0.0.1:${PORT}/job/demo-app/api/json" >/dev/null 2>&1; then
  url="http://127.0.0.1:${PORT}/job/demo-app/config.xml"
  echo "Updating Jenkins job demo-app"
else
  url="http://127.0.0.1:${PORT}/createItem?name=demo-app"
  echo "Creating Jenkins job demo-app"
fi

curl -fsS -X POST \
  -u "$JENKINS_USER:$JENKINS_PASSWORD" \
  -H "$crumb_field: $crumb" \
  -H 'Content-Type: application/xml' \
  --data-binary "@$ROOT_DIR/jenkins/job.xml" \
  "$url" >/dev/null

echo "Jenkins job demo-app is configured from app-repo/Jenkinsfile."
