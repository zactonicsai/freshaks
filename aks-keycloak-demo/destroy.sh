#!/usr/bin/env bash
# =============================================================================
# destroy.sh - deletes EVERYTHING that create.sh made, so the bill stops.
#
#   ./destroy.sh         asks "are you sure?" first
#   ./destroy.sh --yes   does not ask
#
# What gets deleted:
#   1. The resource group (cluster, registry, load balancer, public IP, disks -
#      including the Postgres data. It cannot be brought back.)
#   2. The cluster's entry in your kubectl config file.
#   3. The local files .secrets.env and .rendered/ (passwords, certificate).
# =============================================================================
set -euo pipefail

# shellcheck source=config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

command -v az >/dev/null 2>&1 || die "'az' (Azure CLI) is not installed."
az account show >/dev/null 2>&1 || die "You are not logged in to Azure. Run: az login"

step "This will delete resource group '$RESOURCE_GROUP' and everything in it"
info "Subscription: $(az account show --query name --output tsv)"

# Ask first, unless the script was started with --yes.
if [[ "${1:-}" != "--yes" ]]; then
  read -r -p "    Type the resource group name to confirm: " answer
  [[ "$answer" == "$RESOURCE_GROUP" ]] || die "Names do not match. Nothing was deleted."
fi

# -----------------------------------------------------------------------------
step "Step 1: Deleting the resource group (5-10 minutes)"
# -----------------------------------------------------------------------------
# "az group exists" answers true or false.
if [[ "$(az group exists --name "$RESOURCE_GROUP")" == "true" ]]; then
  # Deleting the group deletes the registry and the cluster. Deleting the
  # cluster also deletes its hidden helper group (named MC_...), which holds
  # the nodes, the load balancer, the public IP and the Postgres disk.
  # --yes means "do not ask again". Without --no-wait, the command waits until
  # the delete is really finished.
  az group delete --name "$RESOURCE_GROUP" --yes
  info "Deleted."
else
  info "Resource group is already gone. Skipping."
fi

# -----------------------------------------------------------------------------
step "Step 2: Checking that nothing is left in Azure"
# -----------------------------------------------------------------------------
LEFT=0
if [[ "$(az group exists --name "$RESOURCE_GROUP")" == "true" ]]; then
  warn "Resource group '$RESOURCE_GROUP' still exists."
  LEFT=1
fi
# The hidden helper group is named MC_<group>_<cluster>_<location>.
NODE_GROUP="MC_${RESOURCE_GROUP}_${CLUSTER_NAME}_${LOCATION}"
if [[ "$(az group exists --name "$NODE_GROUP")" == "true" ]]; then
  warn "Helper group '$NODE_GROUP' still exists. Delete it with: az group delete --name $NODE_GROUP --yes"
  LEFT=1
fi
[[ "$LEFT" -eq 0 ]] && info "Nothing left. Azure will stop charging for this demo."

# -----------------------------------------------------------------------------
step "Step 3: Cleaning up kubectl on this computer"
# -----------------------------------------------------------------------------
# "az aks get-credentials" wrote three things into ~/.kube/config: a context,
# a cluster and a user. They point at a cluster that no longer exists.
# "|| true" means: if it is already gone, that is fine, keep going.
if command -v kubectl >/dev/null 2>&1; then
  kubectl config delete-context "$CLUSTER_NAME" >/dev/null 2>&1 || true
  kubectl config delete-cluster "$CLUSTER_NAME" >/dev/null 2>&1 || true
  kubectl config delete-user "clusterUser_${RESOURCE_GROUP}_${CLUSTER_NAME}" >/dev/null 2>&1 || true
  info "Removed '$CLUSTER_NAME' from your kubectl config."
fi

# -----------------------------------------------------------------------------
step "Step 4: Deleting the local password and certificate files"
# -----------------------------------------------------------------------------
# These belonged to the deleted cluster. A new ./create.sh makes fresh ones.
rm -f "$SECRETS_FILE"
rm -rf "$RENDER_DIR"
info "Removed .secrets.env and .rendered/"

step "Done"
[[ "$LEFT" -eq 0 ]] || die "Something was left behind. Read the warnings above."
