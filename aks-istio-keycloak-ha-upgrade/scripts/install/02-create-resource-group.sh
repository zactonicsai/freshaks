#!/usr/bin/env bash
# =============================================================================
# 02-create-resource-group.sh — create the resource group that holds everything.
# Deleting this one group later removes every Azure resource of the example.
# Usage: ./scripts/install/02-create-resource-group.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Announce the step.
step "Create resource group ${RESOURCE_GROUP} in ${LOCATION}"
# Creating a group that already exists changes nothing, so re-running is safe.
# The tag makes it easy to find (and clean up) the example later.
run az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --tags purpose=aks-ha-upgrade-example --output table
