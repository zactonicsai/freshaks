#!/usr/bin/env bash
# =============================================================================
#  destroy/03-destroy-disks.sh — delete leftover managed disks and snapshots
# =============================================================================
#  After the workloads and the cluster are gone, what is left are:
#    * disks behind PVs that had reclaimPolicy=Retain
#    * disks that were pre-provisioned by hand in RESOURCE_GROUP
#    * orphans in the node RG if the cluster deletion did not remove it
#  This script deletes DATA disks (osType empty) that are not attached to
#  anything. Attached disks (managedBy set) are reported and skipped — delete
#  or stop the VM / pod that holds them first.
#
#  Scope: RESOURCE_GROUP, plus the node RG when INCLUDE_NODE_RG=true and it
#  still exists.
#
#  Azure CLI commands used:
#     az disk list -g <rg> -o json                   disks with osType / managedBy / size
#     az disk delete --ids <id> --yes --no-wait      start deletion of one disk
#     az disk wait --ids <id> --deleted              block until it is gone
#     az snapshot list -g <rg>                       snapshots
#     az snapshot delete --ids <id>                  delete one snapshot
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check

hr
warn "This deletes every UNATTACHED data disk and every snapshot in $RESOURCE_GROUP$( [[ "$INCLUDE_NODE_RG" == "true" ]] && printf ' and %s' "$NODE_RESOURCE_GROUP")."
confirm "$CLUSTER_NAME"

# delete_disks_in_rg <resource group>
delete_disks_in_rg() {
  local rg="$1"
  if ! rg_exists "$rg"; then log "Resource group $rg does not exist — skipping"; return 0; fi
  hr
  log "Managed disks in $rg"
  local json id name os managed size
  local pending=()
  json="$(az disk list -g "$rg" -o json)"
  while IFS='|' read -r id name os managed size; do
    [[ -z "$id" ]] && continue
    if [[ -n "$os" ]]; then
      log "  skip $name (OS disk of ${managed##*/})"
      continue
    fi
    if [[ -n "$managed" ]]; then
      warn "  skip $name (${size}GiB): still attached to ${managed##*/} — detach / delete the consumer first"
      continue
    fi
    log "  delete $name (${size}GiB)"
    run az disk delete --ids "$id" --yes --no-wait || warn "could not start deletion of $name"
    pending+=("$id")
  done < <(jq -r '.[] | [.id, .name, (.osType // ""), (.managedBy // ""), (.diskSizeGb|tostring)] | join("|")' <<<"$json")

  local p
  for p in "${pending[@]:-}"; do
    [[ -z "$p" ]] && continue
    run az disk wait --ids "$p" --deleted --timeout 600 || warn "timed out waiting for ${p##*/}"
  done

  log "Snapshots in $rg"
  json="$(az snapshot list -g "$rg" -o json)"
  while IFS='|' read -r id name; do
    [[ -z "$id" ]] && continue
    log "  delete snapshot $name"
    run az snapshot delete --ids "$id" || warn "could not delete snapshot $name"
  done < <(jq -r '.[] | [.id, .name] | join("|")' <<<"$json")
}

delete_disks_in_rg "$RESOURCE_GROUP"
if [[ "$INCLUDE_NODE_RG" == "true" && -n "$NODE_RESOURCE_GROUP" ]]; then
  delete_disks_in_rg "$NODE_RESOURCE_GROUP"
fi

hr
ok "Disk clean-up finished. Next: ./destroy/04-destroy-networking.sh"
