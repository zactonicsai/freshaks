#!/usr/bin/env bash
# =============================================================================
#  lib/common.sh — helpers shared by every script. Do not run this directly.
#  Each numbered script starts with:   source "$(dirname "$0")/lib/common.sh"
# =============================================================================
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$LIB_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
GENERATED_ENV="$SCRIPTS_DIR/.generated.env"      # values discovered while running (ACR name, ingress IP...)
export LIB_DIR SCRIPTS_DIR ROOT_DIR GENERATED_ENV

# shellcheck source=../00-config.sh
source "$SCRIPTS_DIR/00-config.sh"
if [[ -f "$GENERATED_ENV" ]]; then
  # shellcheck source=/dev/null
  source "$GENERATED_ENV"
fi

# ---- pretty printing ---------------------------------------------------------
log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Missing command '$c'. See docs/01-step-by-step-setup.md (Prerequisites)."
  done
}

# ---- values derived from config --------------------------------------------
if [[ "${ENABLE_TLS:-false}" == "true" ]]; then
  PROTO="https"; SSL_REQUIRED="external"
else
  PROTO="http";  SSL_REQUIRED="none"
fi
export PROTO SSL_REQUIRED

KEYCLOAK_INTERNAL_URL="http://keycloak.${NS_IDENTITY}.svc.cluster.local"
LDAP_URL="ldap://openldap.${NS_IDENTITY}.svc.cluster.local:389"
POSTGRES_HOST="postgres.${NS_DATA}.svc.cluster.local"
export KEYCLOAK_INTERNAL_URL LDAP_URL POSTGRES_HOST

if [[ -n "${BASE_DOMAIN:-}" ]]; then
  KEYCLOAK_PUBLIC_URL="${PROTO}://keycloak.${BASE_DOMAIN}"
  JAVA_URL="${PROTO}://java.${BASE_DOMAIN}"
  PYTHON_URL="${PROTO}://python.${BASE_DOMAIN}"
  export KEYCLOAK_PUBLIC_URL JAVA_URL PYTHON_URL
fi
if [[ -n "${ACR_NAME:-}" ]]; then
  REGISTRY="${ACR_NAME}.azurecr.io"; export REGISTRY
fi

# Fail early with a friendly message when a value from an earlier step is missing.
need_generated() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "'$v' is not known yet. Run the earlier numbered scripts first (values are saved in scripts/.generated.env)."
  done
}

# ---- sed that works on both Linux (GNU) and macOS (BSD) -----------------------
sed_inplace() {
  if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

# Save KEY=VALUE into scripts/.generated.env (update the line if it exists — a tiny sed example)
save_generated() {
  local key="$1" val="$2"
  touch "$GENERATED_ENV"
  if grep -q "^export ${key}=" "$GENERATED_ENV"; then
    sed_inplace "s|^export ${key}=.*|export ${key}=\"${val}\"|" "$GENERATED_ENV"
  else
    printf 'export %s="%s"\n' "$key" "$val" >> "$GENERATED_ENV"
  fi
  export "${key}=${val}"
  log "saved ${key}=${val} -> scripts/.generated.env"
}

# ---- templates: k8s/*.yaml files contain ${VARIABLES}; envsubst fills them in --
# Only the variables listed here are replaced (so a "$" inside an embedded script is left alone).
# shellcheck disable=SC2016  # the ${...} names are meant to be literal: envsubst reads them
TEMPLATE_VARS='${PROJECT} ${NS_IDENTITY} ${NS_DATA} ${NS_APPS} ${NS_TESTS} ${PG_ADMIN_PASSWORD} ${KC_DB_PASSWORD} ${APP_DB_PASSWORD} ${KC_REALM} ${KC_ADMIN_USER} ${KC_ADMIN_PASSWORD} ${DEMO_USER_PASSWORD} ${LDAP_ORGANISATION} ${LDAP_DOMAIN} ${LDAP_BASE_DN} ${LDAP_ADMIN_PASSWORD} ${LDAP_URL} ${REGISTRY} ${IMAGE_TAG} ${BASE_DOMAIN} ${PROTO} ${KEYCLOAK_PUBLIC_URL} ${KEYCLOAK_INTERNAL_URL} ${POSTGRES_HOST} ${JAVA_CLIENT_SECRET} ${PYTHON_CLIENT_SECRET} ${TLS_ANNOTATION} ${TLS_SECTION} ${INGRESS_HOST} ${PLAYWRIGHT_VERSION} ${JAVA_URL} ${PYTHON_URL} ${SERVICE_NAME} ${CLIENT_ID} ${CLIENT_SECRET} ${INGRESS_IP}'
export TEMPLATE_VARS

render()         { envsubst "$TEMPLATE_VARS" < "$1"; }
apply_template() { log "apply $(basename "$1")"; render "$1" | kubectl apply -f -; }

ensure_namespace() {
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

wait_rollout() { # namespace, kind/name, [timeout]
  kubectl -n "$1" rollout status "$2" --timeout="${3:-600s}"
}

# Set the three ingress variables for a host. TLS on: cert-manager issues a cert. TLS off: plain http.
ingress_vars() {
  local host="$1"
  INGRESS_HOST="$host"
  if [[ "$ENABLE_TLS" == "true" ]]; then
    TLS_ANNOTATION="cert-manager.io/cluster-issuer: letsencrypt-prod"
    TLS_SECTION=$'  tls:\n    - hosts:\n        - '"${host}"$'\n      secretName: '"${host//./-}-tls"
  else
    # shellcheck disable=SC2089  # the quotes are YAML, not shell: envsubst pastes this text into the manifest
    TLS_ANNOTATION='nginx.ingress.kubernetes.io/ssl-redirect: "false"'
    TLS_SECTION=""
  fi
  # shellcheck disable=SC2090
  export INGRESS_HOST TLS_ANNOTATION TLS_SECTION
}

# ---- Keycloak admin CLI (kcadm) run inside the Keycloak pod ------------------
kc_pod() {
  kubectl -n "$NS_IDENTITY" get pod -l app.kubernetes.io/name=keycloak \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'
}
kcadm() {
  kubectl -n "$NS_IDENTITY" exec -i "$(kc_pod)" -- /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config
}
kcadm_login() {
  kcadm config credentials --server http://localhost:8080 --realm master \
    --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PASSWORD" >/dev/null
}

print_urls() {
  cat <<EOT

  Keycloak admin console : ${KEYCLOAK_PUBLIC_URL:-<run 02 first>}/admin/   (user: ${KC_ADMIN_USER})
  Java store (Spring)    : ${JAVA_URL:-<run 02 first>}
  Python deli (Flask)    : ${PYTHON_URL:-<run 02 first>}
  Demo users             : sam.shopper / casey.cashier / morgan.manager  (password: ${DEMO_USER_PASSWORD})
  LDAP users             : alex.ldap / jordan.ldap / riley.ldap           (password: ${DEMO_USER_PASSWORD})
EOT
}
