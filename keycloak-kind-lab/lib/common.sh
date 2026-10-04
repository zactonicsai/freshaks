#!/usr/bin/env bash
# Shared settings and helpers. Sourced by the other scripts.
# shellcheck disable=SC2034  # vars are used by the scripts that source this file
set -euo pipefail

# Stop Git Bash on Windows from rewriting paths like /opt/... in kubectl args
export MSYS_NO_PATHCONV=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS="$ROOT_DIR/manifests"
CHARTS="$ROOT_DIR/charts"
BACKUPS="$ROOT_DIR/backups"

CLUSTER_NAME="${CLUSTER_NAME:-mycluster}"
CONTEXT="kind-${CLUSTER_NAME}"
KC_URL="${KC_URL:-http://localhost:8080}"

# Optional chart version pins (empty = latest)
ISTIO_VERSION="${ISTIO_VERSION:-}"
KEYCLOAKX_VERSION="${KEYCLOAKX_VERSION:-}"

DB_NS=db
DB_USER="admin"
DB_NAME=keycloak
KC_NS=keycloak
KC_RELEASE=keycloak
KEEP_BACKUPS=10

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

require() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is not installed or not in PATH"
  done
}

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; }

# Always target our cluster, whatever the current context is
k() { kubectl --context "$CONTEXT" "$@"; }
h() { helm --kube-context "$CONTEXT" "$@"; }

ensure_ns() {
  k create namespace "$1" --dry-run=client -o yaml | k apply -f - >/dev/null
}

# Wait until Postgres accepts real TCP connections (not just the init-time server)
wait_for_postgres() {
  k rollout status deployment/postgres -n "$DB_NS" --timeout=300s
  local i
  for _ in $(seq 1 60); do
    if k exec -n "$DB_NS" deploy/postgres -- \
         pg_isready -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "Postgres did not become ready"
}
