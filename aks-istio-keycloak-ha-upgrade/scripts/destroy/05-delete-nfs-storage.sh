#!/usr/bin/env bash
# =============================================================================
# 05-delete-nfs-storage.sh — remove the shared volumes and the NFS server,
# including the Azure disk (or Azure Files shares) behind them.
# The volumes use the reclaim policy "Retain" (a safety net against accidents),
# so each volume is switched to "Delete" first; then Kubernetes removes the
# Azure resource together with the claim.
# Run 01, 02 and 03 first: a volume that is still mounted cannot be deleted.
# Usage: ./scripts/destroy/05-delete-nfs-storage.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster
# Ask before destroying data.
confirm "Delete the shared volumes (database dumps, notes) and the NFS server with its disk?" || fail "stopped by user"

# Delete one claim together with the storage behind it.
delete_claim() {
  # $1 = namespace, $2 = claim name.
  local namespace="$1" claim="$2" volume
  # Name of the PersistentVolume bound to the claim (empty when the claim is gone).
  volume="$(kubectl --namespace "${namespace}" get persistentvolumeclaim "${claim}" --output jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  # Switch the volume from "Retain" to "Delete" so the storage is removed too.
  if [[ -n "${volume}" ]]; then run kubectl patch persistentvolume "${volume}" --patch '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'; fi
  # Delete the claim; --timeout stops the wait when a pod still uses it.
  run kubectl --namespace "${namespace}" delete persistentvolumeclaim "${claim}" --ignore-not-found --timeout=120s
}

# Announce the step.
step "Delete the shared claims"
# Notes volume of the applications.
delete_claim apps shared-notes
# Backup volume of PostgreSQL.
delete_claim postgres pg-backups

# The NFS server pod only exists for the default backend.
if [[ "${STORAGE_BACKEND}" == "nfs-pod" ]]; then
  # Announce the step.
  step "Uninstall the NFS server"
  # Removes the StatefulSet, the Service, the StorageClass "nfs" and the PriorityClass.
  helm_remove nfs-server-provisioner nfs-storage
  # Announce the step.
  step "Delete the Azure disk behind the NFS server"
  # The claim of the StatefulSet; with policy "Delete" the disk goes with it.
  delete_claim nfs-storage data-nfs-server-provisioner-0
  # Announce the step.
  step "Delete the StorageClass of the disk behind the NFS server"
  # It was created with kubectl, so Helm does not remove it.
  run kubectl delete storageclass nfs-backing-disk --ignore-not-found
else
  # Announce the step.
  step "Delete the Azure Files StorageClass"
  # The shares were deleted together with their claims above.
  run kubectl delete storageclass azurefile-csi-nfs --ignore-not-found
fi

# Announce the step.
step "Show what is left"
# Only volumes that do not belong to this example should remain.
run kubectl get persistentvolumes
