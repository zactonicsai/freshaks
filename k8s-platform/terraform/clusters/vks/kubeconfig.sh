#!/usr/bin/env bash
# Driver contract: write a kubeconfig for $CLUSTER to $KUBECONFIG.
# Exit non-zero when the cluster does not exist.
set -Eeuo pipefail
: "${CLUSTER:?}" "${CONFIG_FILE:?}" "${KUBECONFIG:?}"

supervisor="$(yq -r '.cluster.supervisor.kubeconfig // "~/.kube/config"' "$CONFIG_FILE")"
supervisor="${supervisor/#\~/$HOME}"
context="$(yq -r '.cluster.supervisor.context // ""' "$CONFIG_FILE")"
namespace="$(yq -r '.cluster.supervisor.namespace' "$CONFIG_FILE")"

# Cluster API keeps the admin kubeconfig of each cluster in a Secret next to the Cluster object.
args=(--kubeconfig "$supervisor" --namespace "$namespace")
[[ -z "$context" ]] || args+=(--context "$context")
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
kubectl "${args[@]}" get secret "$CLUSTER-kubeconfig" -o jsonpath='{.data.value}' | base64 -d >"$tmp"
[[ -s "$tmp" ]] || {
  echo "secret $CLUSTER-kubeconfig in namespace $namespace holds no kubeconfig" >&2
  exit 1
}
install -m 600 "$tmp" "$KUBECONFIG"
