#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

: "${BB_USER:?set BB_USER}"
: "${BB_PASS:?set BB_PASS}"
BB_PROJECT="${BB_PROJECT:-DEMO}"
BB_HOST="${BB_HOST:-http://localhost:7990}"
BRANCH="${BRANCH:-master}"

push_repo() {
  local name="$1"
  local src="$2"
  local dest
  dest="$(mktemp -d)"
  echo "== pushing ${name} from ${src} =="
  git clone "${BB_HOST}/scm/${BB_PROJECT}/${name}.git" "${dest}"
  # empty repo clone may have no checkout
  cp -a "${src}/." "${dest}/"
  (
    cd "${dest}"
    git checkout -B "${BRANCH}"
    git add .
    if git diff --cached --quiet; then
      echo "nothing to commit in ${name}"
    else
      git config user.email "lab@local"
      git config user.name "Lab Bootstrap"
      git commit -m "bootstrap ${name}"
    fi
    git push -u origin "${BRANCH}"
  )
  rm -rf "${dest}"
}

export GIT_ASKPASS="${ROOT}/scripts/git-askpass.sh"
export LAB_GIT_USER="${BB_USER}"
export LAB_GIT_PASS="${BB_PASS}"
chmod +x "${ROOT}/scripts/git-askpass.sh"

# Prefer embedding credentials for a one-shot lab push
AUTH_HOST="${BB_HOST/http:\/\//http://${BB_USER}:${BB_PASS}@}"

push_one() {
  local name="$1"
  local src="$2"
  local dest
  dest="$(mktemp -d)"
  echo "== ${name} =="
  if ! git clone "${AUTH_HOST}/scm/${BB_PROJECT}/${name}.git" "${dest}"; then
    echo "clone failed — create the empty repo ${BB_PROJECT}/${name} in the Bitbucket UI first"
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
echo "Repos pushed. Register the Argo CD repo + Application next."
echo "  ./scripts/06-register-argocd-app.sh"
