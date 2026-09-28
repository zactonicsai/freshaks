#!/usr/bin/env bash
# =============================================================================
#  03-install-postgres.sh — the notebook in the back office (one Postgres,
#  two databases: 'keycloak' and 'grocery').
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd kubectl envsubst

step "1/3 Namespace '${NS_DATA}'"
ensure_namespace "$NS_DATA"

step "2/3 Secret + first-start SQL script + StatefulSet + Service"
apply_template "$ROOT_DIR/k8s/postgres/secret.yaml"
# The init script is stored with --from-file so its own $VARIABLES are not touched by envsubst.
kubectl -n "$NS_DATA" create configmap postgres-init \
  --from-file=10-create-databases.sh="$ROOT_DIR/k8s/postgres/init.sh" \
  --dry-run=client -o yaml | kubectl apply -f -
apply_template "$ROOT_DIR/k8s/postgres/statefulset.yaml"
apply_template "$ROOT_DIR/k8s/postgres/service.yaml"

step "3/3 Waiting for Postgres to be ready"
wait_rollout "$NS_DATA" statefulset/postgres
kubectl -n "$NS_DATA" exec statefulset/postgres -- psql -U postgres -c '\l' | grep -E 'keycloak|grocery' \
  || warn "databases not visible yet (first start still running?). Re-run this script in a minute."

log "Done. Postgres is at ${POSTGRES_HOST}:5432. Next: scripts/04-install-openldap.sh"
