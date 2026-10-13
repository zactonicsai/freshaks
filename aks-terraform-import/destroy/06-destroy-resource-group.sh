#!/usr/bin/env bash
# =============================================================================
#  destroy/06-destroy-resource-group.sh — delete the resource group (az cli)
# =============================================================================
#  The nuclear option: deleting the resource group deletes EVERYTHING inside
#  it, whether or not the earlier scripts ran. Azure handles the dependency
#  order itself. Things it does NOT remove:
#    * the AKS node resource group (only the cluster deletion does that — run
#      02-destroy-aks-cluster.sh first, or the MC_ group is orphaned)
#    * soft-deleted Key Vaults (purge separately; see 05)
#    * role assignments at other scopes, resources in other resource groups
#
#  Options (env vars)
#    DELETE_LOCKS=false   remove CanNotDelete/ReadOnly locks first (otherwise the delete fails)
#
#  Azure CLI commands used:
#     az aks show                                 refuse to run while the cluster still exists (orphaned MC_ group)
#     az lock list -g <rg>                        management locks on the group or its resources
#     az lock delete --ids <id>                   (opt-in) remove a lock
#     az group delete -n <rg> --yes --no-wait     start deletion
#     az group wait -n <rg> --deleted             block until gone
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
DELETE_LOCKS="${DELETE_LOCKS:-false}"

if ! rg_exists "$RESOURCE_GROUP"; then
  log "Resource group $RESOURCE_GROUP does not exist — nothing to do."
  exit 0
fi

if az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -o none 2>/dev/null; then
  warn "Cluster $CLUSTER_NAME still exists. Deleting the group now would orphan its node resource group."
  warn "Run ./destroy/02-destroy-aks-cluster.sh first (or set FORCE_RG_DELETE=true to proceed anyway)."
  if [[ "${FORCE_RG_DELETE:-false}" != "true" ]]; then exit 1; fi
fi

hr
warn "This deletes resource group $RESOURCE_GROUP and EVERYTHING in it."
az resource list -g "$RESOURCE_GROUP" --query '[].{type:type,name:name}' -o table 2>/dev/null | sed 's/^/    /' || true
confirm "$RESOURCE_GROUP"

# --- Locks -------------------------------------------------------------------------
locks="$(az lock list -g "$RESOURCE_GROUP" -o json 2>/dev/null || echo '[]')"
if [[ "$(jq 'length' <<<"$locks")" -gt 0 ]]; then
  if [[ "$DELETE_LOCKS" == "true" ]]; then
    while IFS= read -r lid; do
      [[ -z "$lid" ]] && continue
      log "  delete lock ${lid##*/}"
      run az lock delete --ids "$lid" || warn "could not delete lock $lid"
    done < <(jq -r '.[].id' <<<"$locks")
  else
    jq -r '.[] | "    \(.level) lock: \(.name)"' <<<"$locks" >&2
    die "Management locks are present — the delete would fail. Re-run with DELETE_LOCKS=true."
  fi
fi

# --- Delete ------------------------------------------------------------------------
log "az group delete (async)"
run az group delete -n "$RESOURCE_GROUP" --yes --no-wait
log "Waiting for the group to disappear ..."
run az group wait -n "$RESOURCE_GROUP" --deleted --timeout 3600 || warn "az group wait timed out — check 'az group show -n $RESOURCE_GROUP'"

hr
ok "Resource group $RESOURCE_GROUP deleted."
log "If Terraform state still references these resources, run ./destroy/90-reset-terraform-state.sh"
