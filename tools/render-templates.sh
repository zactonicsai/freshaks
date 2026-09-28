#!/usr/bin/env bash
# =============================================================================
#  tools/render-templates.sh — show what a k8s template looks like AFTER the
#  ${VARIABLES} are filled in (without applying anything). Great for learning.
#
#    tools/render-templates.sh k8s/apps/java/deployment.yaml
#    tools/render-templates.sh k8s/tests/*.yaml
#    tools/render-templates.sh --tls k8s/apps/java/ingress.yaml     # see the https version
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"
require_cmd envsubst
if [[ "${1:-}" == "--tls" ]]; then shift; ENABLE_TLS=true; PROTO=https; export ENABLE_TLS PROTO; fi
[[ $# -gt 0 ]] || die "usage: tools/render-templates.sh [--tls] <template.yaml> [more.yaml ...]"
# sensible stand-ins for values that only exist after the cluster is created
: "${BASE_DOMAIN:=1.2.3.4.nip.io}"; : "${REGISTRY:=myacr.azurecr.io}"; : "${INGRESS_IP:=1.2.3.4}"
KEYCLOAK_PUBLIC_URL="${PROTO}://keycloak.${BASE_DOMAIN}"; JAVA_URL="${PROTO}://java.${BASE_DOMAIN}"; PYTHON_URL="${PROTO}://python.${BASE_DOMAIN}"
SERVICE_NAME="${SERVICE_NAME:-example}"; CLIENT_ID="${CLIENT_ID:-grocery-example-app}"; CLIENT_SECRET="${CLIENT_SECRET:-example-secret}"
export BASE_DOMAIN REGISTRY INGRESS_IP KEYCLOAK_PUBLIC_URL JAVA_URL PYTHON_URL SERVICE_NAME CLIENT_ID CLIENT_SECRET
ingress_vars "${INGRESS_HOST:-example.${BASE_DOMAIN}}"
for f in "$@"; do
  echo "---"
  echo "# ===== $f ====="
  render "$f"
  echo
done
