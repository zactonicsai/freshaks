#!/usr/bin/env bash
# =============================================================================
# 03-create-acr.sh — create the Azure Container Registry (ACR) that stores the
# images of the two applications.
# Usage: ./scripts/install/03-create-acr.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Registry names are global in Azure (they become <name>.azurecr.io), so a
# unique name is generated once and remembered in the state file.
if [[ -z "${ACR_NAME}" ]]; then
  # Announce the step.
  step "Generate a unique registry name"
  # Only lowercase letters and digits are allowed: strip everything else from
  # the prefix and add 8 random hex characters.
  generated_name="acr$(printf '%s' "${PREFIX}" | tr -cd 'a-z0-9')$(openssl rand -hex 4)"
  # Remember it, so the next run uses the same registry.
  state_set ACR_NAME "${generated_name}"
fi

# Announce the step.
step "Create container registry ${ACR_NAME} (tier ${ACR_SKU})"
# Admin user stays disabled: the cluster pulls with its managed identity.
# Creating a registry that already exists changes nothing.
run az acr create --resource-group "${RESOURCE_GROUP}" --name "${ACR_NAME}" --sku "${ACR_SKU}" --location "${LOCATION}" --admin-enabled false --output table

# Announce the step.
step "Remember the registry address"
# The login server is the host name used in image names, e.g. acrx.azurecr.io
login_server="$(az acr show --name "${ACR_NAME}" --query loginServer --output tsv)"
# Store it for the build and deploy scripts.
state_set ACR_LOGIN_SERVER "${login_server}"
# Store the name too (needed when ACR_NAME came from the environment).
state_set ACR_NAME "${ACR_NAME}"
# Report success.
ok "registry: ${ACR_LOGIN_SERVER}"
