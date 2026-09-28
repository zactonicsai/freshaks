#!/usr/bin/env bash
# =============================================================================
#  tools/add-role.sh — add a new badge (realm role) and a matching group.
#
#    tools/add-role.sh stocker "Fills the shelves"
#
#  What it does:
#   1. creates realm role <name> in Keycloak (live, via kcadm)
#   2. creates group <name>s and maps the role to it
#   3. adds the role to the realm JSON file so a fresh install has it too
#  Then follow docs/tutorials/tutorial-add-a-stocker-role.md to USE the role in an app.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"
require_cmd kubectl jq

ROLE="${1:-}"; DESC="${2:-$ROLE badge}"
[[ -n "$ROLE" ]] || die "usage: tools/add-role.sh <role-name> [description]"
GROUP="${ROLE}s"
REALM_FILE="$ROOT_DIR/helm/keycloak/realms/${KC_REALM}-realm.json"

step "1/3 Keycloak: role '${ROLE}' and group '${GROUP}'"
kcadm_login
if kcadm get "roles/${ROLE}" -r "$KC_REALM" >/dev/null 2>&1; then
  log "role ${ROLE} already exists"
else
  kcadm create roles -r "$KC_REALM" -s "name=${ROLE}" -s "description=${DESC}"
fi
GROUP_ID="$(kcadm get groups -r "$KC_REALM" -q "search=${GROUP}" -q exact=true | jq -r '.[0].id // empty')"
if [[ -z "$GROUP_ID" ]]; then
  kcadm create groups -r "$KC_REALM" -s "name=${GROUP}"
  GROUP_ID="$(kcadm get groups -r "$KC_REALM" -q "search=${GROUP}" -q exact=true | jq -r '.[0].id')"
fi
kcadm add-roles -r "$KC_REALM" --gid "$GROUP_ID" --rolename "$ROLE"
log "group ${GROUP} (${GROUP_ID}) -> role ${ROLE}"

step "2/3 Realm file: $(basename "$REALM_FILE")"
tmp="$(mktemp)"
jq --arg role "$ROLE" --arg desc "$DESC" --arg group "$GROUP" '
  if any(.roles.realm[]; .name == $role) then . else
    .roles.realm += [{name: $role, description: $desc, composite: false, clientRole: false}] end
  | if any(.groups[]; .name == $group) then . else
    .groups += [{name: $group, path: ("/" + $group), realmRoles: [$role], subGroups: []}] end
' "$REALM_FILE" > "$tmp" && mv "$tmp" "$REALM_FILE"
log "added to realm file"

step "3/3 Next steps (by hand)"
cat <<EOT
  * Put someone in the group:      tools/kcadm.sh update users/<id>/groups/${GROUP_ID} -r ${KC_REALM}
    (or in the admin console: Users -> pick one -> Groups -> Join ${GROUP})
  * Protect a door with it:
      Java   : .requestMatchers("/app/stockroom.html").hasRole("${ROLE}")   in SecurityConfig.java
               @PreAuthorize("hasRole('${ROLE}')")                           on a controller method
      Python : @roles_required("${ROLE}")                                     in app.py
  * Rebuild + redeploy:  scripts/07-build-images.sh && scripts/08-deploy-apps.sh
EOT
