#!/usr/bin/env bash
# =============================================================================
#  06-configure-realm.sh — connect Keycloak to the OpenLDAP phone book and
#  map LDAP groups (cashiers, managers) to Keycloak groups → roles.
#  Uses kcadm (Keycloak's admin CLI) inside the Keycloak pod. Re-runnable.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd kubectl jq envsubst

LDAP_NAME="freshmart-ldap"
MAPPER_NAME="ldap-groups"

step "1/5 Logging in to Keycloak with kcadm"
kcadm_login
REALM_ID="$(kcadm get "realms/${KC_REALM}" --fields id 2>/dev/null | jq -r .id)"
[[ -n "$REALM_ID" && "$REALM_ID" != "null" ]] || die "Realm ${KC_REALM} not found. Run 05 first."
log "realm id ${REALM_ID}"

step "2/5 LDAP user federation '${LDAP_NAME}'"
LDAP_ID="$(kcadm get components -r "$KC_REALM" -q "name=${LDAP_NAME}" -q type=org.keycloak.storage.UserStorageProvider 2>/dev/null | jq -r '.[0].id // empty')"
if [[ -z "$LDAP_ID" ]]; then
  export REALM_ID
  render "$ROOT_DIR/k8s/keycloak/ldap-federation.json" \
    | sed "s|__REALM_ID__|${REALM_ID}|" \
    | kcadm create components -r "$KC_REALM" -f - 2>&1 | tee /tmp/kc-ldap.out
  LDAP_ID="$(kcadm get components -r "$KC_REALM" -q "name=${LDAP_NAME}" | jq -r '.[0].id')"
  log "created LDAP federation ${LDAP_ID}"
else
  log "LDAP federation already exists (${LDAP_ID})"
fi

step "3/5 Group mapper '${MAPPER_NAME}' (LDAP groups → Keycloak groups)"
MAPPER_ID="$(kcadm get components -r "$KC_REALM" -q "name=${MAPPER_NAME}" -q "parent=${LDAP_ID}" 2>/dev/null | jq -r '.[0].id // empty')"
if [[ -z "$MAPPER_ID" ]]; then
  render "$ROOT_DIR/k8s/keycloak/ldap-group-mapper.json" \
    | sed "s|__LDAP_ID__|${LDAP_ID}|" \
    | kcadm create components -r "$KC_REALM" -f -
  MAPPER_ID="$(kcadm get components -r "$KC_REALM" -q "name=${MAPPER_NAME}" -q "parent=${LDAP_ID}" | jq -r '.[0].id')"
  log "created group mapper ${MAPPER_ID}"
else
  log "group mapper already exists (${MAPPER_ID})"
fi

step "4/5 Sync: groups first, then all users"
kcadm create "user-storage/${LDAP_ID}/mappers/${MAPPER_ID}/sync?direction=fedToKeycloak" -r "$KC_REALM"
kcadm create "user-storage/${LDAP_ID}/sync?action=triggerFullSync" -r "$KC_REALM"

step "5/5 Who is in the realm now?"
kcadm get users -r "$KC_REALM" --fields username,email,federationLink | jq -r '.[] | "\(.username)\t\(.email // "-")\t\(if .federationLink then "from LDAP" else "local" end)"' | column -t
echo
log "Groups → roles (from the realm file):  shoppers→shopper, cashiers→cashier, managers→manager+cashier"
log "Done. Next: scripts/07-build-images.sh"
