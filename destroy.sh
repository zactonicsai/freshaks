#!/usr/bin/env bash
set +e

export RG="${RG:-rg-aks-keycloak-dev}"
export AKS="${AKS:-aks-keycloak-dev}"
export NS="${NS:-keycloak}"

echo "Destroying Keycloak / AKS / RG (ignore not found)"

# Helm release
helm uninstall keycloak -n "$NS" >/dev/null 2>&1

# Namespace
kubectl delete namespace "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1

# AKS
az aks delete --resource-group "$RG" --name "$AKS" --yes --no-wait >/dev/null 2>&1

# Resource group (deletes AKS + node RG contents)
az group delete --name "$RG" --yes --no-wait >/dev/null 2>&1

echo "Delete requested."
echo "Check:"
echo "  az aks show -g $RG -n $AKS --query provisioningState -o tsv"
echo "  az group show -n $RG --query properties.provisioningState -o tsv"