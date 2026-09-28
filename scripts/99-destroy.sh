#!/usr/bin/env bash
# =============================================================================
#  99-destroy.sh — tear everything down (deletes the whole resource group).
#  This stops the Azure bill. Type the resource group name to confirm.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd az
echo "This will DELETE resource group '${RESOURCE_GROUP}' and everything in it (cluster, registry, disks)."
read -r -p "Type the resource group name to confirm: " answer
[[ "$answer" == "$RESOURCE_GROUP" ]] || die "Not confirmed. Nothing deleted."
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
rm -f "$GENERATED_ENV" "$ROOT_DIR/helm/keycloak/values-generated.yaml"
log "Deletion started in the background. Check with: az group show -n ${RESOURCE_GROUP}"
