#!/usr/bin/env bash
# Driver contract: write a kubeconfig for $CLUSTER to $KUBECONFIG.
# Exit non-zero when the cluster does not exist.
set -Eeuo pipefail
: "${CLUSTER:?}" "${CONFIG_FILE:?}" "${KUBECONFIG:?}"

region="$(yq -r '.cluster.region' "$CONFIG_FILE")"
group="$(yq -r '.cluster.resourceGroup' "$CONFIG_FILE")"

# Log in only when the CLI has no session, with the same API key Terraform uses.
if ! ibmcloud account show >/dev/null 2>&1; then
  ibmcloud login --apikey "${IC_API_KEY:?set IC_API_KEY or log in with ibmcloud first}" \
    -r "$region" -g "$group" -q >/dev/null
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.flat"' EXIT
KUBECONFIG="$tmp" ibmcloud ks cluster config --cluster "$CLUSTER" --admin -q >/dev/null
# The CLI stores certificates in separate files; inline them so the file stands alone.
KUBECONFIG="$tmp" kubectl config view --raw --minify --flatten >"$tmp.flat"
install -m 600 "$tmp.flat" "$KUBECONFIG"
