#!/usr/bin/env bash
# =============================================================================
#  04-install-openldap.sh — the phone book. Seeds 3 users + 2 groups from
#  k8s/openldap/seed.ldif (edit that file to add people).
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd kubectl envsubst

step "1/3 Namespace '${NS_IDENTITY}'"
ensure_namespace "$NS_IDENTITY"

step "2/3 Secret + seed LDIF + Deployment + Service"
apply_template "$ROOT_DIR/k8s/openldap/secret.yaml"
mkdir -p "$ROOT_DIR/.rendered"
render "$ROOT_DIR/k8s/openldap/seed.ldif" > "$ROOT_DIR/.rendered/seed.ldif"
kubectl -n "$NS_IDENTITY" create configmap openldap-seed \
  --from-file=10-seed.ldif="$ROOT_DIR/.rendered/seed.ldif" \
  --dry-run=client -o yaml | kubectl apply -f -
apply_template "$ROOT_DIR/k8s/openldap/deployment.yaml"
apply_template "$ROOT_DIR/k8s/openldap/service.yaml"

step "3/3 Waiting for OpenLDAP and listing the people in the phone book"
wait_rollout "$NS_IDENTITY" deployment/openldap
sleep 5
kubectl -n "$NS_IDENTITY" exec deployment/openldap -- \
  ldapsearch -x -H ldap://localhost -b "ou=people,${LDAP_BASE_DN}" \
  -D "cn=admin,${LDAP_BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" "(uid=*)" uid cn mail 2>/dev/null \
  | grep -E '^(uid|cn|mail):' || warn "seed not visible yet; re-run this script in a minute"

log "Done. LDAP is at ${LDAP_URL}. Next: scripts/05-install-keycloak.sh"
