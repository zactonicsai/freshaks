#!/usr/bin/env bash
# =============================================================================
#  08-deploy-apps.sh — deploy the Java store and the Python deli. Both log in
#  through Keycloak (realm 'grocery') and write to the shared Postgres.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd kubectl envsubst
need_generated BASE_DOMAIN REGISTRY

step "1/4 Namespace '${NS_APPS}' + shared secrets"
ensure_namespace "$NS_APPS"
apply_template "$ROOT_DIR/k8s/apps/secrets.yaml"

step "2/4 Java store (Spring Boot)"
ingress_vars "java.${BASE_DOMAIN}"
for f in deployment service ingress; do apply_template "$ROOT_DIR/k8s/apps/java/${f}.yaml"; done

step "3/4 Python deli (Flask)"
ingress_vars "python.${BASE_DOMAIN}"
for f in deployment service ingress; do apply_template "$ROOT_DIR/k8s/apps/python/${f}.yaml"; done

step "4/4 Waiting for both apps"
wait_rollout "$NS_APPS" deployment/java-store
wait_rollout "$NS_APPS" deployment/python-deli
kubectl -n "$NS_APPS" get pods,ingress

log "Done."
print_urls
log "Next: scripts/09-run-tests.sh"
