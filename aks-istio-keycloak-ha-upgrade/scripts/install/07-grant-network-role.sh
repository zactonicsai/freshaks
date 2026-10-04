#!/usr/bin/env bash
# =============================================================================
# 07-grant-network-role.sh — allow the cluster to attach our static public IP
# to its load balancer.
# The IP lives in OUR resource group, not in the node resource group that AKS
# manages, so the cluster's identity needs the "Network Contributor" role there.
# Usage: ./scripts/install/07-grant-network-role.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Announce the step.
step "Look up the identity of the cluster and the id of the resource group"
# Object id of the cluster's managed identity (it creates the load balancer rules).
principal_id="$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --query identity.principalId --output tsv)"
# Full Azure resource id of the resource group (the scope of the role).
group_id="$(az group show --name "${RESOURCE_GROUP}" --query id --output tsv)"
# Show both.
info "cluster identity: ${principal_id}"
# Show the scope.
info "scope: ${group_id}"

# Announce the step.
step "Assign the role 'Network Contributor'"
# --assignee-object-id with --assignee-principal-type avoids a directory
# look-up that can fail for brand-new identities. Assigning twice is harmless.
run az role assignment create --assignee-object-id "${principal_id}" --assignee-principal-type ServicePrincipal --role "Network Contributor" --scope "${group_id}" --output table
# Role assignments can take a minute to become active; the cloud controller
# simply retries until the load balancer is ready.
info "the role can take up to a few minutes to become active"
