#!/usr/bin/env bash
# =============================================================================
#  import/07-import-acr.sh — Azure Container Registry
# =============================================================================
#   Azure object          Terraform resource type       Import ID
#   -------------------   ---------------------------   ----------------------------------------------
#   Container registry    azurerm_container_registry    .../Microsoft.ContainerRegistry/registries/<name>
#
#  Sources:
#    1. Every registry in RESOURCE_GROUP.
#    2. Registries attached to the cluster. `az aks update --attach-acr` works by
#       granting the kubelet identity the AcrPull role on the registry, so the
#       kubelet identity's role assignments reveal them wherever they live.
#    3. Any names listed in ACR_NAMES (config.env).
#
#  Azure CLI commands used:
#     az acr list -g <rg>                                            registries in the RG
#     az aks show ... --query identityProfile.kubeletidentity.objectId  kubelet identity principal
#     az role assignment list --assignee <principal> --all           find AcrPull scopes (attached registries)
#     az acr show -n <name>                                          resolve an ACR name to its ARM ID
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
tf_import_begin acr

# --- 1. Registries in the resource group --------------------------------------
json="$(az acr list -g "$RESOURCE_GROUP" -o json)"
while IFS='|' read -r name id sku server; do
  [[ -z "$name" ]] && continue
  tf_import_add azurerm_container_registry "$(tf_name "$name")" "$id" "Container registry $server ($sku)"
done < <(jq -r '.[] | [.name, .id, .sku.name, .loginServer] | join("|")' <<<"$json")

# --- 2. Registries attached to the cluster (AcrPull for the kubelet identity) -
kubelet_principal="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query identityProfile.kubeletidentity.objectId -o tsv 2>/dev/null || true)"
if [[ -n "$kubelet_principal" ]]; then
  log "Checking registries attached to the cluster (AcrPull on kubelet identity)"
  while IFS= read -r scope; do
    [[ -z "$scope" ]] && continue
    tf_import_add azurerm_container_registry "$(tf_name "${scope##*/}")" "$scope" "Container registry attached to $CLUSTER_NAME"
  done < <(az role assignment list --assignee "$kubelet_principal" --all -o json 2>/dev/null \
            | jq -r '.[] | select(.roleDefinitionName == "AcrPull") | .scope | select(test("/registries/[^/]+$"))')
fi

# --- 3. Explicitly named registries ------------------------------------------
for name in $ACR_NAMES; do
  id="$(az acr show -n "$name" --query id -o tsv 2>/dev/null || true)"
  if [[ -z "$id" ]]; then warn "ACR_NAMES: registry '$name' not found"; continue; fi
  tf_import_add azurerm_container_registry "$(tf_name "$name")" "$id" "Container registry $name (from ACR_NAMES)"
done

tf_import_end
