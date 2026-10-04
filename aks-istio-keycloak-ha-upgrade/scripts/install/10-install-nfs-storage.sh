#!/usr/bin/env bash
# =============================================================================
# 10-install-nfs-storage.sh — set up shared (ReadWriteMany) storage.
# Default backend "nfs-pod": an NFS server pod whose data lives on an Azure
# managed disk. Alternative "azurefiles-nfs": Azure Files NFS shares.
# Then create the two shared volumes: database backups and application notes.
# Usage: ./scripts/install/10-install-nfs-storage.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster

# Two ways to provide NFS; pick by STORAGE_BACKEND from config/env.sh.
if [[ "${STORAGE_BACKEND}" == "nfs-pod" ]]; then
  # Announce the step.
  step "Create the StorageClass for the disk behind the NFS pod (${NFS_BACKING_DISK_SKU})"
  # An Azure managed disk class with "Retain", so the disk survives mistakes.
  kapply "${ROOT_DIR}/k8s/storage/nfs-backing-disk-storageclass.yaml"

  # Announce the step.
  step "Install the NFS server pod (chart nfs-server-provisioner ${NFS_CHART_VERSION})"
  # Helm installs a StatefulSet with one pod and the StorageClass "nfs".
  deploy_nfs

  # Announce the step.
  step "Wait until the NFS server pod is ready"
  # The pod is ready when the disk is attached and the NFS server answers.
  wait_rollout nfs-storage statefulset/nfs-server-provisioner
else
  # Announce the step.
  step "Create the StorageClass for Azure Files NFS shares"
  # No pod to install: Azure runs the NFS service.
  kapply "${ROOT_DIR}/k8s/storage/azurefile-nfs-storageclass.yaml"
fi

# Announce the step.
step "Create the shared volume claims (class ${SHARED_STORAGE_CLASS})"
# Volume for database dumps, mounted by the old and the new PostgreSQL.
kapply "${ROOT_DIR}/k8s/storage/pvc-pg-backups.yaml"
# Volume for notes, mounted by all four application pods.
kapply "${ROOT_DIR}/k8s/storage/pvc-shared-notes.yaml"

# Announce the step.
step "Wait until both claims are bound to a volume"
# "Bound" means the storage exists and is reserved for the claim.
run kubectl --namespace postgres wait --for=jsonpath='{.status.phase}'=Bound persistentvolumeclaim/pg-backups --timeout=10m
# Same for the notes volume.
run kubectl --namespace apps wait --for=jsonpath='{.status.phase}'=Bound persistentvolumeclaim/shared-notes --timeout=10m

# Announce the step.
step "Show storage classes and claims"
# Lists the classes; "nfs" (or azurefile-csi-nfs) is the shared one.
run kubectl get storageclass
# Lists the claims in all namespaces with size and access mode.
run kubectl get persistentvolumeclaim --all-namespaces
