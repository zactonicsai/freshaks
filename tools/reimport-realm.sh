#!/usr/bin/env bash
# =============================================================================
#  tools/reimport-realm.sh — push helm/keycloak/realms/<realm>.json into a
#  RUNNING Keycloak (the Helm import only happens on the very first start).
#
#  It renders the __PLACEHOLDERS__ the same way the Helm chart does, then uses
#  the "partial import" API with OVERWRITE, so edited clients/roles/users win.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"
require_cmd kubectl jq
need_generated BASE_DOMAIN

FILE="${1:-$ROOT_DIR/helm/keycloak/realms/${KC_REALM}-realm.json}"
[[ -f "$FILE" ]] || die "realm file not found: $FILE"

step "Rendering $(basename "$FILE")"
RENDERED="$(sed \
  -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
  -e "s|__PROTO__|${PROTO}|g" \
  -e "s|__SSL_REQUIRED__|${SSL_REQUIRED}|g" \
  -e "s|__DEMO_PASSWORD__|${DEMO_USER_PASSWORD}|g" \
  -e "s|__JAVA_CLIENT_SECRET__|${JAVA_CLIENT_SECRET}|g" \
  -e "s|__PYTHON_CLIENT_SECRET__|${PYTHON_CLIENT_SECRET}|g" \
  "$FILE")"

step "Partial import with OVERWRITE into realm ${KC_REALM}"
kcadm_login
# partialImport wants: ifResourceExists + the pieces to import
echo "$RENDERED" | jq '{ifResourceExists: "OVERWRITE", roles: .roles, groups: .groups, clients: .clients, users: .users}' \
  | kcadm create "realms/${KC_REALM}/partialImport" -f -

step "Realm settings (sslRequired etc.)"
echo "$RENDERED" | jq 'del(.roles, .groups, .clients, .users, .id)' \
  | kcadm update "realms/${KC_REALM}" -f -

log "Done. Users/clients/roles now match ${FILE}."
log "LDAP users are not in the file; run scripts/06-configure-realm.sh again if you need to re-sync them."
