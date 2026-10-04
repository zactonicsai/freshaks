#!/usr/bin/env bash
# =============================================================================
# 07-delete-azure-resources.sh — delete the resource group and with it every
# Azure resource of the example: registry, public IP and (if step 06 was
# skipped) the cluster. After this step nothing is billed any more.
# Usage: ./scripts/destroy/07-delete-azure-resources.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# "az group exists" prints true or false.
if [[ "$(az group exists --name "${RESOURCE_GROUP}")" != "true" ]]; then
  # Tell the user and stop successfully.
  ok "resource group ${RESOURCE_GROUP} does not exist - nothing to do"
  # Leave the script with "success".
  exit 0
fi

# Announce the step.
step "Show what is in resource group ${RESOURCE_GROUP}"
# Name and type of every resource that is about to be deleted.
run az resource list --resource-group "${RESOURCE_GROUP}" --query "[].{name:name, type:type}" --output table

# Ask before deleting.
confirm "DELETE resource group ${RESOURCE_GROUP} and everything listed above?" || fail "stopped by user"

# Announce the step.
step "Delete resource group ${RESOURCE_GROUP}"
# --yes skips Azure's own question; the command returns when everything is gone.
run az group delete --name "${RESOURCE_GROUP}" --yes

# Final message.
ok "all Azure resources of the example are deleted"
# A hint about a group Azure may have created on its own.
info "Azure sometimes creates a resource group 'NetworkWatcherRG' by itself; it is free and not part of this example."
