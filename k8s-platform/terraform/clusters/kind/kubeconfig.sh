#!/usr/bin/env bash
# Driver contract: write a kubeconfig for $CLUSTER to $KUBECONFIG.
# Exit non-zero when the cluster does not exist.
set -Eeuo pipefail
: "${CLUSTER:?}" "${CONFIG_FILE:?}" "${KUBECONFIG:?}"

KIND_EXPERIMENTAL_PROVIDER="$(yq -r '.cluster.runtime // "docker"' "$CONFIG_FILE")"
export KIND_EXPERIMENTAL_PROVIDER

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
kind get kubeconfig --name "$CLUSTER" >"$tmp"
install -m 600 "$tmp" "$KUBECONFIG"
