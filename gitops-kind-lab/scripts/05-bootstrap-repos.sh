#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GITEA_USER="${GITEA_USER:-gitea_admin}"
GITEA_PASS="${GITEA_PASS:-LabPass123!}"
GITEA_HOST="${GITEA_HOST:-http://localhost:3000}"
BRANCH="${BRANCH:-main}"

AUTH_HOST="${GITEA_HOST/http:\/\//http://${GITEA_USER}:${GITEA_PASS}@}"

push_one() {
  local name="$1"
  local src="$2"
  local dest
  dest="$(mktemp -d)"
  echo "== ${name} =="
  if ! git clone "${AUTH_HOST}/${GITEA_USER}/${name}.git" "${dest}"; then
    echo "clone failed — run ./scripts/03-install-gitea.sh first"
    rm -rf "${dest}"
    return 1
  fi
  cp -a "${src}/." "${dest}/"
  (
    cd "${dest}"
    git checkout -B "${BRANCH}" || true
    git add .
    git config user.email "lab@local"
    git config user.name "Lab Bootstrap"
    git diff --cached --quiet || git commit -m "bootstrap ${name}"
    git push -u origin "${BRANCH}"
  )
  rm -rf "${dest}"
}

push_one "demo-app" "${ROOT}/sample-app"
push_one "demo-gitops" "${ROOT}/gitops"

echo
echo "Repos pushed."
echo "  ${GITEA_HOST}/${GITEA_USER}/demo-app"
echo "  ${GITEA_HOST}/${GITEA_USER}/demo-gitops"
echo "Next: ./scripts/06-register-argocd-app.sh"
