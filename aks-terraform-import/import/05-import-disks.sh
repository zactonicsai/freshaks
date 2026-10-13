#!/usr/bin/env bash
# =============================================================================
#  import/05-import-disks.sh — Managed disks and snapshots
# =============================================================================
#   Azure object        Terraform resource type   Import ID
#   -----------------   -----------------------   ---------------------------------------
#   Managed data disk   azurerm_managed_disk      .../Microsoft.Compute/disks/<name>
#   Snapshot            azurerm_snapshot          .../Microsoft.Compute/snapshots/<name>
#
#  Three sources of disks are combined:
#    1. Disks behind Kubernetes PersistentVolumes. The Azure Disk CSI driver
#       stores the full disk ARM ID in  PV.spec.csi.volumeHandle  (legacy
#       in-tree volumes:  PV.spec.azureDisk.diskURI). These normally live in
#       the NODE resource group and are the disks you care about when you
#       destroy — a PVC with reclaimPolicy=Retain leaves its disk behind.
#    2. Every data disk in RESOURCE_GROUP (pre-provisioned / static PVs).
#    3. With INCLUDE_NODE_RG=true, every data disk in the node RG as well
#       (orphans that no PV references any more).
#  OS disks (osType set — they belong to the VM scale sets) are always skipped.
#
#  Also writes out/disk-map.csv: disk id -> PV -> PVC -> reclaim policy, which
#  is what the destroy scripts and your future self need.
#
#  kubectl commands used:
#     kubectl get pv -o json        every PersistentVolume with its CSI volume handle
#  Azure CLI commands used:
#     az disk list -g <rg> -o json  every managed disk in a resource group (osType, managedBy, size, SKU)
#     az snapshot list -g <rg>      disk snapshots
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
require_tools kubectl
aks_credentials
tf_import_begin disks

DISK_MAP="$OUT_DIR/disk-map.csv"
printf 'disk_id,pv,pvc,reclaim_policy,storage_class,phase\n' >"$DISK_MAP"

# --- 1. Disks referenced by PersistentVolumes --------------------------------
log "Mapping PersistentVolumes -> Azure disks"
pvs="$(kubectl get pv -o json)"
while IFS='|' read -r disk_id pv pvc policy sc phase; do
  [[ -z "$disk_id" ]] && continue
  printf '%s,%s,%s,%s,%s,%s\n' "$disk_id" "$pv" "$pvc" "$policy" "$sc" "$phase" >>"$DISK_MAP"
  tf_import_add azurerm_managed_disk "$(tf_name "${disk_id##*/}")" "$disk_id" \
    "PV $pv -> PVC $pvc (reclaim $policy, class $sc, $phase)"
done < <(jq -r '
  .items[]
  | select((.spec.csi.driver // "") == "disk.csi.azure.com" or (.spec.azureDisk != null))
  | [ (.spec.csi.volumeHandle // .spec.azureDisk.diskURI),
      .metadata.name,
      ((.spec.claimRef.namespace // "-") + "/" + (.spec.claimRef.name // "-")),
      .spec.persistentVolumeReclaimPolicy,
      (.spec.storageClassName // ""),
      .status.phase ]
  | join("|")' <<<"$pvs")

# --- 2. / 3. Disks by resource group -----------------------------------------
# import_disks_in_rg <resource group>
import_disks_in_rg() {
  local rg="$1"
  hr
  log "Scanning managed disks in resource group: $rg"
  local json id name os managed size sku
  json="$(az disk list -g "$rg" -o json)"
  while IFS='|' read -r id name os managed size sku; do
    [[ -z "$id" ]] && continue
    if [[ -n "$os" ]]; then
      log "  skip $name: OS disk owned by ${managed##*/}"
      continue
    fi
    local note="Data disk $name (${size}GiB $sku)"
    if [[ -n "$managed" ]]; then note="$note attached to ${managed##*/}"; fi
    tf_import_add azurerm_managed_disk "$(tf_name "$name")" "$id" "$note"
  done < <(jq -r '.[] | [.id, .name, (.osType // ""), (.managedBy // ""), (.diskSizeGb|tostring), (.sku.name // "")] | join("|")' <<<"$json")

  log "Scanning snapshots in resource group: $rg"
  json="$(az snapshot list -g "$rg" -o json)"
  while IFS='|' read -r id name; do
    [[ -z "$id" ]] && continue
    tf_import_add azurerm_snapshot "$(tf_name "$name")" "$id" "Snapshot $name"
  done < <(jq -r '.[] | [.id, .name] | join("|")' <<<"$json")
}

import_disks_in_rg "$RESOURCE_GROUP"
if [[ "$INCLUDE_NODE_RG" == "true" ]] && rg_exists "$NODE_RESOURCE_GROUP"; then
  warn "INCLUDE_NODE_RG=true: scanning node RG disks too (PVC disks already found above are skipped as duplicates)"
  import_disks_in_rg "$NODE_RESOURCE_GROUP"
fi

hr
log "Disk <-> PV map written to ${DISK_MAP#$ROOT_DIR/}"
tf_import_end
