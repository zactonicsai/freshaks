#!/usr/bin/env bash
# =============================================================================
# apply-all.sh — create the whole example with Terraform/OpenTofu: the three
# layers in order, with the image build in between, then the same smoke test
# and login test as the shell example (about 30 minutes).
# Each "apply" shows its plan and asks for approval; set ASSUME_YES=true to
# skip the questions.
# Usage: ./terraform/scripts/apply-all.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"
# Load the Terraform helpers.
# shellcheck source=tf-lib.sh
source "${ROOT_DIR}/terraform/scripts/tf-lib.sh"

# Build the option list for apply (with or without -auto-approve). It is used
# below as ${TF_APPROVE[@]+"${TF_APPROVE[@]}"}: that form expands to nothing
# for an empty list without tripping "set -u" on the bash 3.2 of macOS.
tf_approve_options

# Announce the step.
step "Layer 1: Azure resources (resource group, registry, public IP, AKS)"
# Download the providers named in versions.tf.
tf 01-infra init -input=false
# Create or update the resources.
tf 01-infra apply ${TF_APPROVE[@]+"${TF_APPROVE[@]}"}

# Announce the step.
step "Build and push the application images"
# Also writes the kubeconfig and the registry address into .state.
run_script ../terraform/scripts/build-images.sh "${APP_VERSION_OLD}"

# Announce the step.
step "Layer 2: namespaces, NFS storage, Istio, TLS certificate, gateways"
# Download the providers.
tf 02-platform init -input=false
# Create or update the resources.
tf 02-platform apply ${TF_APPROVE[@]+"${TF_APPROVE[@]}"}

# Announce the step.
step "Layer 3: PostgreSQL, Keycloak, the applications, policies and routes"
# Download the providers.
tf 03-workloads init -input=false
# Create or update the resources.
tf 03-workloads apply ${TF_APPROVE[@]+"${TF_APPROVE[@]}"}

# Announce the step.
step "Test the result"
# Copy the CA certificate and the test password into .state.
run_script ../terraform/scripts/sync-local-state.sh
# Public endpoints, redirects and access rules.
run_script install/24-smoke-test.sh
# Full OIDC login, single sign-on, shared volume, egress.
run_script tools/test-login.sh
# Print the addresses and the test logins.
run_script tools/show-urls.sh
