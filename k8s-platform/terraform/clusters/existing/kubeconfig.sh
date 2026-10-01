#!/usr/bin/env bash
# Driver: a cluster that already exists (Docker Desktop, k3s, OpenShift, GKE, on-prem...).
# This folder has no Terraform, so nothing is created or destroyed.
# Driver contract: write a kubeconfig for $CLUSTER to $KUBECONFIG.
set -Eeuo pipefail
: "${CLUSTER:?}" "${CONFIG_FILE:?}" "${KUBECONFIG:?}"

# SOURCE_KUBECONFIG (for example a Jenkins secret file) wins over cluster.kubeconfig.
source_file="${SOURCE_KUBECONFIG:-$(yq -r '.cluster.kubeconfig // "~/.kube/config"' "$CONFIG_FILE")}"
source_file="${source_file/#\~/$HOME}"
context="$(yq -r '.cluster.context // ""' "$CONFIG_FILE")"
[[ -f "$source_file" ]] || {
  echo "kubeconfig not found: $source_file" >&2
  exit 1
}

# Copy only the one context in use, with certificates inlined.
args=(config view --raw --minify --flatten)
[[ -z "$context" ]] || args+=(--context "$context")
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
KUBECONFIG="$source_file" kubectl "${args[@]}" >"$tmp"
install -m 600 "$tmp" "$KUBECONFIG"
