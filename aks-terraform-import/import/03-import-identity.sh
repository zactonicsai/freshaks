#!/usr/bin/env bash
# =============================================================================
#  import/03-import-identity.sh — Managed identities and RBAC
# =============================================================================
#   Azure object                        Terraform resource type               Import ID
#   ---------------------------------   -----------------------------------   ------------------------------------
#   User-assigned managed identity      azurerm_user_assigned_identity        identity ARM ID
#   Federated credential (workload id)  azurerm_federated_identity_credential credential ARM ID
#   Role assignment                     azurerm_role_assignment               "<scope>/providers/Microsoft.Authorization/roleAssignments/<guid>"
#
#  Which role assignments are collected:
#    * every assignment held by each user-assigned identity in RESOURCE_GROUP
#    * every assignment held by the cluster's control-plane identity
#      (system- or user-assigned) — e.g. Network Contributor on the VNet
#    * every assignment held by the kubelet identity — e.g. AcrPull on a
#      registry granted by `az aks update --attach-acr`
#
#  Azure CLI commands used:
#     az identity list -g <rg>                                         user-assigned identities (id, principalId, clientId)
#     az identity federated-credential list -g <rg> --identity-name <n> workload-identity federated credentials
#     az aks show -g <rg> -n <cluster>                                  control-plane and kubelet identity principal IDs
#     az role assignment list --assignee <principalId> --all            every role assignment of a principal, at any scope
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
tf_import_begin identity

# import_role_assignments <principal object id> <label used in TF names>
import_role_assignments() {
  local principal="$1" label="$2"
  local ras
  # --all = all scopes in the subscription (RG, resource, subscription itself).
  ras="$(az role assignment list --assignee "$principal" --all -o json 2>/dev/null || echo '[]')"
  local ra_id role scope guid
  while IFS='|' read -r ra_id role scope guid; do
    [[ -z "$ra_id" ]] && continue
    tf_import_add azurerm_role_assignment "$(tf_name "${label}_${role}_${guid:0:8}")" "$ra_id" \
      "$label has '$role' on ${scope}"
  done < <(jq -r '.[] | [.id, .roleDefinitionName, .scope, .name] | join("|")' <<<"$ras")
}

# --- 1. User-assigned identities in the resource group ----------------------
ids_json="$(az identity list -g "$RESOURCE_GROUP" -o json)"
while IFS='|' read -r name id principal; do
  [[ -z "$name" ]] && continue
  tf_import_add azurerm_user_assigned_identity "$(tf_name "$name")" "$id" "User-assigned identity $name"

  # Federated credentials (Entra Workload ID: service account <-> identity trust)
  feds="$(az identity federated-credential list -g "$RESOURCE_GROUP" --identity-name "$name" -o json 2>/dev/null || echo '[]')"
  while IFS='|' read -r fname fid subject; do
    [[ -z "$fname" ]] && continue
    tf_import_add azurerm_federated_identity_credential "$(tf_name "${name}_${fname}")" "$fid" \
      "Federated credential $fname on $name (subject: $subject)"
  done < <(jq -r '.[] | [.name, .id, (.subject // "")] | join("|")' <<<"$feds")

  import_role_assignments "$principal" "$name"
done < <(jq -r '.[] | [.name, .id, .principalId] | join("|")' <<<"$ids_json")

# --- 2. Identities used by the cluster itself --------------------------------
cluster_json="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -o json)"

# Control plane identity: system-assigned (principalId on the cluster) or
# user-assigned (keys of identity.userAssignedIdentities).
cp_principal="$(jq -r '.identity.principalId // empty' <<<"$cluster_json")"
if [[ -n "$cp_principal" ]]; then
  log "Control-plane identity (system-assigned) principal: $cp_principal"
  import_role_assignments "$cp_principal" "${CLUSTER_NAME}_controlplane"
fi
while IFS='|' read -r ua_id ua_principal; do
  [[ -z "$ua_id" ]] && continue
  log "Control-plane identity (user-assigned): $ua_id"
  # The identity object may live outside RESOURCE_GROUP; import it anyway.
  tf_import_add azurerm_user_assigned_identity "$(tf_name "${ua_id##*/}")" "$ua_id" "Cluster control-plane identity"
  import_role_assignments "$ua_principal" "${ua_id##*/}"
done < <(jq -r '.identity.userAssignedIdentities // {} | to_entries[] | [.key, (.value.principalId // "")] | join("|")' <<<"$cluster_json")

# Kubelet identity: the identity nodes use to pull images / attach disks.
# AKS creates it in the node RG when none is supplied; its role assignments
# (AcrPull ...) are still worth tracking so Terraform can remove them cleanly.
kubelet_principal="$(jq -r '.identityProfile.kubeletidentity.objectId // empty' <<<"$cluster_json")"
kubelet_id="$(jq -r '.identityProfile.kubeletidentity.resourceId // empty' <<<"$cluster_json")"
if [[ -n "$kubelet_principal" ]]; then
  log "Kubelet identity: ${kubelet_id:-$kubelet_principal}"
  # ARM IDs are case-insensitive ("resourcegroups" vs "resourceGroups"), so compare lower-cased.
  kubelet_id_lc="$(tr '[:upper:]' '[:lower:]' <<<"$kubelet_id")"
  node_rg_lc="$(tr '[:upper:]' '[:lower:]' <<<"$NODE_RESOURCE_GROUP")"
  if [[ -n "$kubelet_id" ]] && [[ "$INCLUDE_NODE_RG" == "true" || -z "$node_rg_lc" || "$kubelet_id_lc" != *"/resourcegroups/${node_rg_lc}/"* ]]; then
    tf_import_add azurerm_user_assigned_identity "$(tf_name "${kubelet_id##*/}")" "$kubelet_id" "Kubelet identity"
  else
    log "  kubelet identity lives in the node RG and is AKS-managed; not importing the identity object itself"
  fi
  import_role_assignments "$kubelet_principal" "${CLUSTER_NAME}_kubelet"
fi

tf_import_end
