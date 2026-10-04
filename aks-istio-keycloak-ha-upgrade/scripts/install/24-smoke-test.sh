#!/usr/bin/env bash
# =============================================================================
# 24-smoke-test.sh — quick end-to-end check from this machine, through the
# Azure load balancer and the Istio ingress gateway, to all three services.
# It is also run after every upgrade stage. It changes nothing.
# Usage: ./scripts/install/24-smoke-test.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# The public address must be known.
require_state PUBLIC_IP "scripts/install/04-create-public-ip.sh"
# The host names must be known.
require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"

# Announce the step.
step "Wait until the three public endpoints answer (up to 3 minutes each)"
# Application 1: public info endpoint.
wait_http "app1 /api/info" 200 180 "https://app1.${BASE_DOMAIN}/api/info"
# Application 2: public info endpoint.
wait_http "app2 /api/info" 200 180 "https://app2.${BASE_DOMAIN}/api/info"
# Keycloak: the OIDC discovery document of realm "demo".
wait_http "keycloak discovery document" 200 180 "https://keycloak.${BASE_DOMAIN}/realms/demo/.well-known/openid-configuration"

# Announce the step.
step "Check redirects and access rules"
# Plain HTTP must be redirected to HTTPS by the gateway.
expect_code "http:// is redirected to https://" 301 "http://app1.${BASE_DOMAIN}/"
# The start pages are public.
expect_code "app1 start page" 200 "https://app1.${BASE_DOMAIN}/"
# Same for application 2.
expect_code "app2 start page" 200 "https://app2.${BASE_DOMAIN}/"
# The API needs a login.
expect_code "app1 API without login is refused" 401 "https://app1.${BASE_DOMAIN}/api/me"
# Same for application 2.
expect_code "app2 API without login is refused" 401 "https://app2.${BASE_DOMAIN}/api/me"
# Health endpoints of Keycloak must not be reachable from the internet.
expect_code "keycloak /health is not public" 404 "https://keycloak.${BASE_DOMAIN}/health/ready"

# Announce the step.
step "Check that Keycloak announces its public address as issuer"
# The issuer inside the discovery document must be the public https URL;
# the applications compare it with the "iss" claim of every token.
if curl_mesh "https://keycloak.${BASE_DOMAIN}/realms/demo/.well-known/openid-configuration" | grep -q "\"issuer\":\"https://keycloak.${BASE_DOMAIN}/realms/demo\""; then ok "issuer is https://keycloak.${BASE_DOMAIN}/realms/demo"; else fail "Keycloak announces a different issuer - check the hostname settings"; fi

# Announce the step.
step "Show which version and pod answered"
# Prints the JSON of /api/info: application name, version and pod name.
curl_mesh "https://app1.${BASE_DOMAIN}/api/info"
# Line break after the JSON.
echo
# Same for application 2.
curl_mesh "https://app2.${BASE_DOMAIN}/api/info"
# Line break after the JSON.
echo
