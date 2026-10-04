#!/usr/bin/env bash
# =============================================================================
# 04-create-public-ip.sh — create the static public IP of the ingress gateway.
# A static IP that we own survives every upgrade (and even a re-creation of the
# cluster), so DNS names and certificates stay valid.
# Usage: ./scripts/install/04-create-public-ip.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Announce the step.
step "Create static public IP ${PUBLIC_IP_NAME} (zone-redundant)"
# Standard SKU + zones 1 2 3 = the address stays reachable when one zone fails.
# ZONES is left unquoted on purpose so "1 2 3" becomes three arguments.
# shellcheck disable=SC2086
run az network public-ip create --resource-group "${RESOURCE_GROUP}" --name "${PUBLIC_IP_NAME}" --location "${LOCATION}" --sku Standard --allocation-method Static --version IPv4 --zone ${ZONES} --output table

# Announce the step.
step "Remember the IP address and derive the host names"
# Read the address that Azure assigned.
ip_address="$(az network public-ip show --resource-group "${RESOURCE_GROUP}" --name "${PUBLIC_IP_NAME}" --query ipAddress --output tsv)"
# Store the IP for later scripts.
state_set PUBLIC_IP "${ip_address}"
# nip.io is a free DNS service: anything.<IP>.nip.io resolves to <IP>.
# This gives us three host names without owning a domain.
state_set BASE_DOMAIN "${ip_address}.nip.io"
# Show the three host names.
ok "host names: app1.${BASE_DOMAIN}  app2.${BASE_DOMAIN}  keycloak.${BASE_DOMAIN}"
