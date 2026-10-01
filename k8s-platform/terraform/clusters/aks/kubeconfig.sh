#!/usr/bin/env bash
# Driver contract: write a kubeconfig for $CLUSTER to $KUBECONFIG.
# Exit non-zero when the cluster does not exist.
set -Eeuo pipefail
: "${CLUSTER:?}" "${CONFIG_FILE:?}" "${KUBECONFIG:?}"

group="$(yq -r '.cluster.resourceGroup // ("rg-" + .cluster.name)' "$CONFIG_FILE")"
subscription="$(yq -r '.cluster.subscriptionId // ""' "$CONFIG_FILE")"
subscription="${subscription:-${ARM_SUBSCRIPTION_ID:-}}"

# Log in only when the az CLI has no session, with the same ARM_* variables Terraform uses.
if ! az account show >/dev/null 2>&1; then
  if [[ -n "${ARM_CLIENT_SECRET:-}" ]]; then
    az login --service-principal --username "$ARM_CLIENT_ID" --password "$ARM_CLIENT_SECRET" \
      --tenant "$ARM_TENANT_ID" >/dev/null
  else
    az login --identity >/dev/null # managed identity of the Jenkins agent
  fi
fi

args=(--resource-group "$group" --name "$CLUSTER")
[[ -z "$subscription" ]] || args+=(--subscription "$subscription")
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
az aks get-credentials "${args[@]}" --file "$tmp" --overwrite-existing >/dev/null
install -m 600 "$tmp" "$KUBECONFIG"
