#!/usr/bin/env bash
# =============================================================================
# verify.sh - checks the demo. It changes nothing. Run it any time.
#
#   Part A looks inside the cluster (are the pods healthy? do they have sidecars?)
#   Part B knocks on the front door from THIS computer (do the pages answer?)
# =============================================================================
set -uo pipefail   # no "-e": we want to run ALL checks even if one fails

# shellcheck source=config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

FAILED=0
pass() { printf '    \033[1;32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '    \033[1;31mFAIL\033[0m  %s\n' "$*"; FAILED=$((FAILED + 1)); }

# ------------------------------ Part A: inside -------------------------------
step "A. Looking inside the cluster"

kubectl get pods --namespace "$NAMESPACE" --output wide || die "kubectl cannot reach the cluster. Run: az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME"

for app in postgres keycloak app; do
  # Is the pod Ready?
  ready="$(kubectl get pods --namespace "$NAMESPACE" --selector "app=$app" \
    --output jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  if [[ "$ready" == "True" ]]; then pass "$app pod is Ready"; else fail "$app pod is not Ready"; fi

  # Does the pod have the Istio sidecar? (It is called "istio-proxy". Newer
  # Istio lists it under initContainers, older under containers. Check both.)
  names="$(kubectl get pods --namespace "$NAMESPACE" --selector "app=$app" \
    --output jsonpath='{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}' 2>/dev/null)"
  if [[ "$names" == *istio-proxy* ]]; then pass "$app pod has an Istio sidecar"; else fail "$app pod has NO Istio sidecar (see README: namespace label gotcha)"; fi
done

# Is the gateway keeping the visitor's real IP address?
policy="$(kubectl get service "$INGRESS_SERVICE" --namespace "$INGRESS_NAMESPACE" --output jsonpath='{.spec.externalTrafficPolicy}' 2>/dev/null)"
if [[ "$policy" == "Local" ]]; then pass "gateway keeps the visitor's real IP (externalTrafficPolicy=Local)"; else fail "externalTrafficPolicy is '$policy', expected 'Local'"; fi

# Is the Azure firewall note on the gateway Service?
ranges="$(kubectl get service "$INGRESS_SERVICE" --namespace "$INGRESS_NAMESPACE" \
  --output jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/azure-allowed-ip-ranges}' 2>/dev/null)"
if [[ "$LOCK_APP_TO_ALLOWED_IP" == "true" ]]; then
  if [[ "$ranges" == "${ALLOWED_IP}/32" ]]; then pass "Azure firewall only allows ${ALLOWED_IP}/32"; else fail "Azure firewall note is '$ranges', expected '${ALLOWED_IP}/32'"; fi
else
  info "App is open to the internet (LOCK_APP_TO_ALLOWED_IP=false). Firewall note: '${ranges:-none}'"
fi

# Are the Istio locks in place?
for item in "authorizationpolicy/keycloak-ip-allowlist/$INGRESS_NAMESPACE" "peerauthentication/default/$NAMESPACE" \
            "authorizationpolicy/keycloak-allow/$NAMESPACE" "authorizationpolicy/postgres-allow/$NAMESPACE" "authorizationpolicy/app-allow/$NAMESPACE"; do
  IFS=/ read -r kind name ns <<< "$item"
  if kubectl get "$kind" "$name" --namespace "$ns" >/dev/null 2>&1; then pass "$kind '$name' exists"; else fail "$kind '$name' is missing"; fi
done

# ------------------------------ Part B: outside ------------------------------
step "B. Knocking on the front door from this computer"

INGRESS_IP="$(kubectl get service "$INGRESS_SERVICE" --namespace "$INGRESS_NAMESPACE" --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
[[ -n "$INGRESS_IP" ]] || die "The gateway has no public IP yet."
APP_HOST="app.${INGRESS_IP}.nip.io"
KC_HOST="keycloak.${INGRESS_IP}.nip.io"
MY_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
info "Gateway IP: $INGRESS_IP    This computer: ${MY_IP:-unknown}    Allowed: $ALLOWED_IP"

# ask HOST PATH -> prints the HTTP status code (200, 302, 403...). "000" means
# no answer at all (blocked by the firewall, or timed out).
#   --insecure   accept our self-signed certificate
#   --resolve    "this name lives at this IP" - so the test works even if
#                nip.io name lookups are blocked on your network
ask() {
  curl --silent --insecure --max-time 15 --output /dev/null --write-out '%{http_code}' \
    --resolve "$1:443:$INGRESS_IP" "https://$1$2"
}
# expect WHAT HOST PATH CODE
expect() {
  local got; got="$(ask "$2" "$3")"
  if [[ "$got" == "$4" ]]; then pass "$1 -> $got"; else fail "$1 -> got $got, expected $4"; fi
}

if [[ "$MY_IP" == "$ALLOWED_IP" ]]; then
  info "You ARE at the allowed address. Everything should answer."
  expect "public page opens without login"          "$APP_HOST" "/"        200
  expect "private page sends you to log in"         "$APP_HOST" "/private" 302
  expect "group page sends you to log in"           "$APP_HOST" "/group"   302
  expect "app health check"                         "$APP_HOST" "/actuator/health/readiness" 200
  expect "Keycloak realm 'demo' answers"            "$KC_HOST"  "/realms/demo/.well-known/openid-configuration" 200
  expect "Keycloak admin console answers"           "$KC_HOST"  "/admin/master/console/" 200
elif [[ "$LOCK_APP_TO_ALLOWED_IP" == "true" ]]; then
  info "You are NOT at the allowed address. Everything should be blocked (000 = no answer)."
  expect "app is blocked for you"                   "$APP_HOST" "/" 000
  expect "Keycloak is blocked for you"              "$KC_HOST"  "/realms/demo/.well-known/openid-configuration" 000
else
  info "You are NOT at the allowed address. The app should answer; Keycloak should say 403."
  expect "public page opens without login"          "$APP_HOST" "/" 200
  expect "Keycloak refuses you (403 = forbidden)"   "$KC_HOST"  "/realms/demo/.well-known/openid-configuration" 403
fi

step "Result"
if [[ "$FAILED" -eq 0 ]]; then
  pass "All checks passed."
else
  fail "$FAILED check(s) did not pass. See README, Troubleshooting."
  exit 1
fi
