#!/usr/bin/env bash
# =============================================================================
#  import/08-import-keyvault.sh — Key Vault
# =============================================================================
#   Azure object      Terraform resource type   Import ID
#   ---------------   -----------------------   ----------------------------------------------------
#   Key vault         azurerm_key_vault         .../Microsoft.KeyVault/vaults/<name>
#   Secret            azurerm_key_vault_secret  https://<vault>.vault.azure.net/secrets/<name>/<version>
#
#  Access policies (when the vault is not RBAC-based) are generated inline in
#  the azurerm_key_vault block. Secrets are only imported with
#  IMPORT_KEYVAULT_SECRETS=true because their VALUES end up in the Terraform
#  state and in the generated HCL.
#
#  Azure CLI commands used:
#     az keyvault list -g <rg> --resource-type vault          vaults in the RG
#     az keyvault secret list --vault-name <v>                secret names (data plane — needs list permission)
#     az keyvault secret show --vault-name <v> -n <s>         the versioned secret URL azurerm expects
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
tf_import_begin keyvault

json="$(az keyvault list -g "$RESOURCE_GROUP" --resource-type vault -o json)"
while IFS='|' read -r name id; do
  [[ -z "$name" ]] && continue
  tf_import_add azurerm_key_vault "$(tf_name "$name")" "$id" "Key vault $name"

  if [[ "$IMPORT_KEYVAULT_SECRETS" != "true" ]]; then continue; fi
  warn "IMPORT_KEYVAULT_SECRETS=true: secret values of $name will be stored in Terraform state"
  while IFS= read -r sname; do
    [[ -z "$sname" ]] && continue
    # azurerm needs the VERSIONED identifier; `secret list` only gives the unversioned one.
    sid="$(az keyvault secret show --vault-name "$name" -n "$sname" --query id -o tsv 2>/dev/null || true)"
    if [[ -z "$sid" ]]; then warn "cannot read secret $name/$sname (no get permission?)"; continue; fi
    tf_import_add azurerm_key_vault_secret "$(tf_name "${name}_${sname}")" "$sid" "Secret $sname in $name"
  done < <(az keyvault secret list --vault-name "$name" -o json 2>/dev/null | jq -r '.[].name')
done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

tf_import_end
