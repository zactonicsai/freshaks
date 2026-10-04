#!/usr/bin/env bash
# =============================================================================
# show-urls.sh — print the addresses and the test logins.
# The passwords are written to your terminal only, not into the log file.
# Usage: ./scripts/tools/show-urls.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# The host names must be known.
require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"

# Announce the step.
step "Addresses"
# First application.
info "Portal   (app1): https://app1.${BASE_DOMAIN}"
# Second application.
info "Reports  (app2): https://app2.${BASE_DOMAIN}"
# Keycloak admin console.
info "Keycloak admin : https://keycloak.${BASE_DOMAIN}/admin/"
# Why the browser shows a warning and how to get rid of it.
info "The certificate is signed by a private CA. Import ${TLS_DIR}/ca.crt as a trusted root, or accept the browser warning for all three host names."
# What to do when a company DNS server refuses nip.io names.
info "If the names do not resolve, add this line to your hosts file: ${PUBLIC_IP} app1.${BASE_DOMAIN} app2.${BASE_DOMAIN} keycloak.${BASE_DOMAIN}"

# Announce the step.
step "Test logins"
# The three users of realm "demo".
info "users: alice (roles user + admin), bob (role user), carol (role user)"
# Where the passwords are stored.
info "passwords are in ${SECRETS_FILE} (TEST_USER_PASSWORD, KEYCLOAK_ADMIN_PASSWORD)"

# Give the log writer a moment to print the lines above first.
sleep 1
# Write the passwords straight to the terminal (/dev/tty), bypassing the log.
# When there is no terminal (for example in a CI job) nothing is printed.
{
  # Empty line.
  printf '\n'
  # Password shared by alice, bob and carol.
  printf '  test users   alice / bob / carol   password: %s\n' "${TEST_USER_PASSWORD:-<not created yet>}"
  # Login for the Keycloak admin console.
  printf '  Keycloak     admin                 password: %s\n' "${KEYCLOAK_ADMIN_PASSWORD:-<not created yet>}"
  # Empty line.
  printf '\n'
  # The redirect sends the block to the terminal; if that fails, say so in the log.
} 2>/dev/null > /dev/tty || info "no terminal attached - passwords not shown"
