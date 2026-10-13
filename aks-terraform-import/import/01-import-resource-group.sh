#!/usr/bin/env bash
# =============================================================================
#  import/01-import-resource-group.sh — Resource Group
# =============================================================================
#  Azure object        Terraform resource        Import ID
#  -----------------   ----------------------    ------------------------------------------
#  Resource group      azurerm_resource_group    /subscriptions/<sub>/resourceGroups/<name>
#
#  The AKS NODE resource group (MC_*) is deliberately NOT imported, even with
#  INCLUDE_NODE_RG=true: it is owned by the managed cluster and is deleted
#  automatically when the cluster is deleted. Importing it would make
#  `terraform destroy` race the AKS resource provider.
#
#  Azure CLI commands used:
#     az group show -n <rg>      returns the resource group's full ARM ID and location
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
tf_import_begin resource_group

rg_json="$(az group show -n "$RESOURCE_GROUP" -o json)"
rg_id="$(jq -r '.id' <<<"$rg_json")"
rg_loc="$(jq -r '.location' <<<"$rg_json")"

tf_import_add azurerm_resource_group "$(tf_name "$RESOURCE_GROUP")" "$rg_id" \
  "Resource group $RESOURCE_GROUP ($rg_loc)"

if [[ -n "$NODE_RESOURCE_GROUP" ]]; then
  log "Node resource group $NODE_RESOURCE_GROUP is managed by AKS and is intentionally not imported."
fi

tf_import_end
