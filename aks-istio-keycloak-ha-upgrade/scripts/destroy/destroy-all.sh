#!/usr/bin/env bash
# =============================================================================
# destroy-all.sh — remove everything.
# Default (fast): delete the cluster, then the resource group, then the local
# state. Deleting the cluster already removes every pod, disk and share.
# With --graceful: first uninstall the workloads one by one (steps 01 to 05),
# which is useful to see - and log - the orderly way to take things down.
# Usage: ./scripts/destroy/destroy-all.sh [--graceful]
#        Unattended: ASSUME_YES=true ./scripts/destroy/destroy-all.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Ask once for everything.
confirm "DESTROY the whole example: cluster ${AKS_NAME}, resource group ${RESOURCE_GROUP} and the local state?" || fail "stopped by user"
# The scripts started below must not ask again.
export ASSUME_YES=true

# Optional orderly removal inside the cluster.
if [[ "${1:-}" == "--graceful" ]]; then
  # The two applications.
  run_script destroy/01-delete-apps.sh
  # Keycloak.
  run_script destroy/02-delete-keycloak.sh
  # PostgreSQL releases and their data volumes.
  run_script destroy/03-delete-postgres.sh
  # Istio.
  run_script destroy/04-delete-istio.sh
  # Shared volumes and the NFS server.
  run_script destroy/05-delete-nfs-storage.sh
fi

# The cluster.
run_script destroy/06-delete-aks-cluster.sh
# The resource group with registry and public IP.
run_script destroy/07-delete-azure-resources.sh
# Passwords, certificates and remembered names on this machine.
run_script destroy/08-clean-local-state.sh
