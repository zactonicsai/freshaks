#!/usr/bin/env bash
# =============================================================================
#  import/06-import-storage.sh — Storage accounts (Azure Files / Blob)
# =============================================================================
#   Azure object        Terraform resource type   Import ID
#   -----------------   -----------------------   -----------------------------------------------------
#   Storage account     azurerm_storage_account   .../Microsoft.Storage/storageAccounts/<name>
#   File share          azurerm_storage_share     https://<account>.file.core.windows.net/<share>
#                                                 (data-plane URL form; see IMPORT_FILE_SHARES note)
#
#  Sources:
#    1. Every storage account in RESOURCE_GROUP.
#    2. Accounts behind Azure Files PersistentVolumes. The Azure File CSI
#       driver encodes the account in  PV.spec.csi.volumeHandle  as
#       "<rg>#<account>#<share>#..." — the account is often auto-created by
#       the driver inside the NODE resource group.
#  File shares are only imported with IMPORT_FILE_SHARES=true. Shares are
#  data-plane objects: `terraform plan` must be able to reach the account's
#  file endpoint (firewall / private endpoint rules apply).
#
#  kubectl commands used:
#     kubectl get pv -o json                          Azure Files PVs and their volume handles
#  Azure CLI commands used:
#     az storage account list -g <rg>                 accounts in the RG (id, kind, sku)
#     az storage account list --query "[?name=='x']"  resolve an account found via a PV to its ARM ID
#     az storage share-rm list --storage-account <a>  file shares through the management plane
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
require_tools kubectl
aks_credentials
tf_import_begin storage

# import_account <account name> <arm id> <note>
import_account() {
  local name="$1" id="$2" note="$3"
  tf_import_add azurerm_storage_account "$(tf_name "$name")" "$id" "$note"
  if [[ "$IMPORT_FILE_SHARES" != "true" ]]; then return 0; fi
  local shares sname
  shares="$(az storage share-rm list --storage-account "$name" -o json 2>/dev/null || echo '[]')"
  while IFS= read -r sname; do
    [[ -z "$sname" ]] && continue
    # azurerm_storage_share import ID — data-plane URL form. If you configure the
    # resource with storage_account_id instead of storage_account_name, replace
    # the ID with the ARM form: <account id>/fileServices/default/shares/<share>
    tf_import_add azurerm_storage_share "$(tf_name "${name}_${sname}")" \
      "https://${name}.file.core.windows.net/${sname}" "File share $sname on $name"
  done < <(jq -r '.[].name' <<<"$shares")
}

# --- 1. Accounts in the resource group ----------------------------------------
json="$(az storage account list -g "$RESOURCE_GROUP" -o json)"
while IFS='|' read -r name id kind sku; do
  [[ -z "$name" ]] && continue
  import_account "$name" "$id" "Storage account $name ($kind, $sku)"
done < <(jq -r '.[] | [.name, .id, .kind, .sku.name] | join("|")' <<<"$json")

# --- 2. Accounts behind Azure Files PVs ---------------------------------------
log "Looking for storage accounts behind Azure Files PersistentVolumes"
pvs="$(kubectl get pv -o json)"
while IFS='|' read -r handle pv pvc; do
  [[ -z "$handle" ]] && continue
  # volumeHandle = "<resourceGroup>#<account>#<share>#<...>"
  acct="$(cut -d'#' -f2 <<<"$handle")"
  [[ -z "$acct" ]] && continue
  acct_id="$(az storage account list --query "[?name=='${acct}'].id" -o tsv 2>/dev/null || true)"
  if [[ -z "$acct_id" ]]; then
    warn "PV $pv references account $acct but it was not found in subscription $SUBSCRIPTION_ID"
    continue
  fi
  import_account "$acct" "$acct_id" "Storage account $acct behind PV $pv (PVC $pvc)"
done < <(jq -r '
  .items[]
  | select((.spec.csi.driver // "") == "file.csi.azure.com")
  | [ .spec.csi.volumeHandle, .metadata.name,
      ((.spec.claimRef.namespace // "-") + "/" + (.spec.claimRef.name // "-")) ]
  | join("|")' <<<"$pvs")

tf_import_end
