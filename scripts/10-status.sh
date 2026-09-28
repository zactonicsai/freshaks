#!/usr/bin/env bash
# =============================================================================
#  10-status.sh — quick health check of everything + the URLs to open.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd kubectl
for ns in "$NS_DATA" "$NS_IDENTITY" "$NS_APPS" "$NS_TESTS"; do
  step "namespace ${ns}"; kubectl -n "$ns" get pods 2>/dev/null || echo "(not created yet)"
done
step "ingress"
kubectl get ingress -A 2>/dev/null || true
if [[ -n "${KEYCLOAK_PUBLIC_URL:-}" ]]; then
  step "http checks"
  for u in "${KEYCLOAK_PUBLIC_URL}/realms/${KC_REALM}/.well-known/openid-configuration" "${JAVA_URL}/actuator/health" "${PYTHON_URL}/healthz"; do
    printf '%-80s %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u" || echo 'no answer')"
  done
fi
print_urls
