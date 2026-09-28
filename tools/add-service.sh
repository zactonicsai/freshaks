#!/usr/bin/env bash
# =============================================================================
#  tools/add-service.sh — register a NEW OIDC service (a new door that trusts
#  the same front office) in three places:
#
#    1. Keycloak: a confidential client "<name>" with the "roles" claim mapper
#    2. Kubernetes: k8s/apps/<name>/ (copied from k8s/_templates/new-service)
#    3. The realm JSON file, so a fresh install has the client too
#
#    tools/add-service.sh bakery                # host: bakery.<BASE_DOMAIN>
#    tools/add-service.sh bakery my-secret-123  # choose the client secret
#
#  Afterwards: put your code in apps/<name>/ with a Dockerfile, then
#    az acr build --registry $ACR_NAME --image freshmart/bakery:$IMAGE_TAG apps/bakery
#    tools/add-service.sh --deploy bakery my-secret-123
#  See docs/09-adding-a-new-service.md for the full story.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"
require_cmd kubectl jq envsubst
need_generated BASE_DOMAIN

DEPLOY=false
if [[ "${1:-}" == "--deploy" ]]; then DEPLOY=true; shift; fi
NAME="${1:-}"
[[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || die "usage: tools/add-service.sh [--deploy] <name-in-lowercase> [client-secret]"
CLIENT_ID="grocery-${NAME}-app"
CLIENT_SECRET="${2:-${NAME}-secret-$(date +%s)}"
HOST="${NAME}.${BASE_DOMAIN}"
REALM_FILE="$ROOT_DIR/helm/keycloak/realms/${KC_REALM}-realm.json"
TARGET_DIR="$ROOT_DIR/k8s/apps/${NAME}"

client_json() {
  jq -n --arg id "$CLIENT_ID" --arg secret "$CLIENT_SECRET" --arg root "${PROTO}://${HOST}" \
        --arg rootTpl "__PROTO__://${NAME}.__BASE_DOMAIN__" --argjson forFile "${1:-false}" '
  {
    clientId: $id,
    name: ($id + " (added by tools/add-service.sh)"),
    enabled: true,
    protocol: "openid-connect",
    publicClient: false,
    secret: $secret,
    standardFlowEnabled: true,
    directAccessGrantsEnabled: false,
    serviceAccountsEnabled: false,
    rootUrl: (if $forFile then $rootTpl else $root end),
    baseUrl: "/",
    redirectUris: [(if $forFile then $rootTpl else $root end) + "/*", "http://localhost:8080/*"],
    webOrigins: ["+"],
    attributes: {"post.logout.redirect.uris": "+", "pkce.code.challenge.method": "S256"},
    protocolMappers: [{
      name: "roles", protocol: "openid-connect", protocolMapper: "oidc-usermodel-realm-role-mapper",
      consentRequired: false,
      config: {"claim.name": "roles", "jsonType.label": "String", "multivalued": "true",
               "id.token.claim": "true", "access.token.claim": "true",
               "userinfo.token.claim": "true", "introspection.token.claim": "true"}
    }]
  }'
}

if ! $DEPLOY; then
  step "1/3 Keycloak client '${CLIENT_ID}'"
  kcadm_login
  EXISTING="$(kcadm get clients -r "$KC_REALM" -q "clientId=${CLIENT_ID}" | jq -r '.[0].id // empty')"
  if [[ -n "$EXISTING" ]]; then
    log "client already exists (${EXISTING}); updating secret + redirect URIs"
    client_json | kcadm update "clients/${EXISTING}" -r "$KC_REALM" -f -
  else
    client_json | kcadm create clients -r "$KC_REALM" -f -
    log "created"
  fi

  step "2/3 Realm file + k8s manifests"
  tmp="$(mktemp)"
  jq --argjson c "$(client_json true | sed "s|${CLIENT_SECRET}|__${NAME^^}_CLIENT_SECRET__|")" '
    .clients |= (map(select(.clientId != $c.clientId)) + [$c])' "$REALM_FILE" > "$tmp" && mv "$tmp" "$REALM_FILE"
  log "client added to $(basename "$REALM_FILE") (secret placeholder __${NAME^^}_CLIENT_SECRET__ —"
  log "   add a 'replace' line for it in helm/keycloak/templates/configmap-realms.yaml if you want Helm to fill it)"
  if [[ -d "$TARGET_DIR" ]]; then
    log "k8s/apps/${NAME} already exists, leaving it alone"
  else
    cp -r "$ROOT_DIR/k8s/_templates/new-service" "$TARGET_DIR"
    log "created k8s/apps/${NAME}/ (deployment, service, ingress) — edit the image/port/env as needed"
  fi

  step "3/3 What next"
  cat <<EOT
  client id     : ${CLIENT_ID}
  client secret : ${CLIENT_SECRET}      (keep it! you need it for --deploy)
  issuer        : ${KEYCLOAK_PUBLIC_URL}/realms/${KC_REALM}
  redirect URI  : ${PROTO}://${HOST}/*
  Write your app in apps/${NAME}/ (copy apps/python-deli-app as a start), build the image, then:
     tools/add-service.sh --deploy ${NAME} '${CLIENT_SECRET}'
EOT
  exit 0
fi

# ---- --deploy --------------------------------------------------------------------
need_generated REGISTRY
[[ -d "$TARGET_DIR" ]] || die "k8s/apps/${NAME} not found. Run without --deploy first."
step "Deploying ${NAME} -> ${PROTO}://${HOST}"
ensure_namespace "$NS_APPS"
export SERVICE_NAME="$NAME" CLIENT_ID CLIENT_SECRET
ingress_vars "$HOST"
for f in "$TARGET_DIR"/*.yaml; do apply_template "$f"; done
wait_rollout "$NS_APPS" "deployment/${NAME}"
log "Done: ${PROTO}://${HOST}"
