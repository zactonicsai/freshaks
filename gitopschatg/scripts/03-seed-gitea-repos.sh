#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITEA_USER="${GITEA_USER:-gitadmin}"
GITEA_PASSWORD="${GITEA_PASSWORD:-gitadmin123}"
PORT="${GITEA_FORWARD_PORT:-13000}"
TMP="$(mktemp -d)"
PF_PID=""
cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

kubectl -n gitea port-forward svc/gitea "${PORT}:3000" >"$TMP/port-forward.log" 2>&1 &
PF_PID=$!
for _ in {1..40}; do
  if curl -fsS "http://127.0.0.1:${PORT}/api/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

create_repo() {
  local repo="$1"
  local code
  code=$(curl -sS -o "$TMP/${repo}.json" -w '%{http_code}' \
    -u "$GITEA_USER:$GITEA_PASSWORD" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${repo}\",\"private\":false,\"auto_init\":false}" \
    "http://127.0.0.1:${PORT}/api/v1/user/repos")
  if [[ "$code" == "201" ]]; then
    echo "Created repo $repo"
  elif [[ "$code" == "409" || "$code" == "422" ]]; then
    echo "Repo $repo already exists."
  else
    echo "Could not create $repo; HTTP $code"
    cat "$TMP/${repo}.json"
    exit 1
  fi
}

push_seed() {
  local repo="$1"
  local source="$2"
  local work="$TMP/$repo"
  cp -R "$source" "$work"
  (
    cd "$work"
    rm -rf .git
    git init -b main >/dev/null
    git config user.name "lab-bootstrap"
    git config user.email "lab-bootstrap@local.lab"
    git add .
    git commit -m "Initial lab content" >/dev/null
    git remote add origin "http://${GITEA_USER}:${GITEA_PASSWORD}@127.0.0.1:${PORT}/${GITEA_USER}/${repo}.git"
    if git ls-remote origin refs/heads/main 2>/dev/null | grep -q .; then
      echo "$repo already has main; leaving existing history unchanged."
    else
      git push -u origin main >/dev/null
      echo "Seeded $repo"
    fi
  )
}

create_repo app-repo
create_repo gitops-repo
push_seed app-repo "$ROOT_DIR/seed/app-repo"
push_seed gitops-repo "$ROOT_DIR/seed/gitops-repo"

echo "Gitea repositories are ready."
