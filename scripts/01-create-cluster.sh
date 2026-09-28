#!/usr/bin/env bash
# =============================================================================
#  01-create-cluster.sh — build the school (AKS cluster) and the supply closet (ACR)
#  Safe to re-run: every step checks whether the thing already exists.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd az kubectl

step "1/5 Logging in to Azure (skips if already logged in)"
az account show >/dev/null 2>&1 || az login >/dev/null
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
log "Using subscription ${SUBSCRIPTION_ID}"

step "2/5 Resource group '${RESOURCE_GROUP}' in ${LOCATION}"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
log "resource group ready"

step "3/5 Container registry (holds the app images we build later)"
if [[ -z "${ACR_NAME:-}" ]]; then
  # registry names must be globally unique: project + first 10 chars of the subscription id
  ACR_NAME="${PROJECT}$(tr -d '-' <<< "$SUBSCRIPTION_ID" | cut -c1-10)"
  save_generated ACR_NAME "$ACR_NAME"
fi
if az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  log "registry ${ACR_NAME} already exists"
else
  az acr create --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --sku Basic --output none
  log "registry ${ACR_NAME} created"
fi
save_generated REGISTRY "${ACR_NAME}.azurecr.io"

step "4/5 AKS cluster '${CLUSTER_NAME}' (this takes 5-10 minutes the first time)"
if az aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  log "cluster already exists — attaching registry just in case"
  az aks update --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --attach-acr "$ACR_NAME" --output none
else
  VERSION_ARGS=()
  [[ -n "${KUBERNETES_VERSION}" ]] && VERSION_ARGS=(--kubernetes-version "$KUBERNETES_VERSION")
  az aks create \
    --name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --node-count "$SYSTEM_NODE_COUNT" \
    --node-vm-size "$SYSTEM_NODE_VM_SIZE" \
    --nodepool-name system \
    --attach-acr "$ACR_NAME" \
    --enable-managed-identity \
    --generate-ssh-keys \
    --tier free \
    "${VERSION_ARGS[@]}" \
    --output none
  log "cluster created"
fi

step "5/5 Fetching kubectl credentials"
az aks get-credentials --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --overwrite-existing --output none
kubectl get nodes -o wide

log "Done. Next: scripts/02-setup-nodes.sh"
