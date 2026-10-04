#!/usr/bin/env bash
# =============================================================================
# destroy-all.sh — remove everything that Terraform created.
# Default: destroy layer 3, then 2, then 1 - the orderly way.
# With --fast: destroy only layer 1 (the Azure resources). Deleting the
# cluster removes everything inside it; the state files of layers 2 and 3 are
# then deleted because what they describe no longer exists.
# Usage: ./terraform/scripts/destroy-all.sh [--fast]
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"
# Load the Terraform helpers.
# shellcheck source=tf-lib.sh
source "${ROOT_DIR}/terraform/scripts/tf-lib.sh"

# Ask once; the destroy commands below then run without further questions.
confirm "DESTROY the Terraform example (cluster, registry, public IP and all data)?" || fail "stopped by user"
# Do not ask again per layer.
ASSUME_YES=true
# Build the option list for destroy.
tf_approve_options

# The orderly way unless --fast was given.
if [[ "${1:-}" != "--fast" ]]; then
  # Announce the step.
  step "Layer 3: applications, Keycloak, PostgreSQL, policies"
  # If this fails half-way, run the script again with --fast.
  tf 03-workloads destroy ${TF_APPROVE[@]+"${TF_APPROVE[@]}"}
  # Announce the step.
  step "Layer 2: gateways, Istio, NFS storage, namespaces"
  # Namespaces are deleted last inside this layer.
  tf 02-platform destroy ${TF_APPROVE[@]+"${TF_APPROVE[@]}"}
fi

# Announce the step.
step "Layer 1: AKS cluster, registry, public IP, resource group"
# This is the step that ends the Azure costs.
tf 01-infra destroy ${TF_APPROVE[@]+"${TF_APPROVE[@]}"}

# Announce the step.
step "Remove state files that describe things that no longer exist"
# After --fast the states of layers 2 and 3 still list objects of the deleted
# cluster; without them a later apply starts clean.
rm -f "${TF_DIR}/02-platform/terraform.tfstate" "${TF_DIR}/02-platform/terraform.tfstate.backup" "${TF_DIR}/03-workloads/terraform.tfstate" "${TF_DIR}/03-workloads/terraform.tfstate.backup"
# The kubeconfig points at a cluster that no longer exists.
rm -f "${KUBECONFIG}"
# Final message.
ok "the Terraform example is destroyed"
