#!/usr/bin/env bash
# Driver contract: write a kubeconfig for $CLUSTER to $KUBECONFIG.
# Exit non-zero when the cluster does not exist.
set -Eeuo pipefail
: "${CLUSTER:?}" "${CONFIG_FILE:?}" "${KUBECONFIG:?}"

region="$(yq -r '.cluster.region' "$CONFIG_FILE")"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# The kubeconfig calls "aws eks get-token", so the aws CLI must stay on PATH.
aws eks update-kubeconfig --name "$CLUSTER" --region "$region" --alias "$CLUSTER" --kubeconfig "$tmp" >/dev/null
install -m 600 "$tmp" "$KUBECONFIG"
