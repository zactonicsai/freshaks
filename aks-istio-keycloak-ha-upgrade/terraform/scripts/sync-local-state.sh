#!/usr/bin/env bash
# =============================================================================
# sync-local-state.sh — copy what Terraform knows (kubeconfig, addresses,
# test password, CA certificate) into the .state folder, so that kubectl and
# the general tools of this project work with the Terraform-built cluster:
#   scripts/install/24-smoke-test.sh, scripts/tools/test-login.sh,
#   scripts/tools/show-urls.sh, scripts/tools/show-status.sh,
#   scripts/tools/availability-probe.sh
# Use a separate checkout for the Terraform example and the shell example:
# both keep their facts in .state.
# Usage: ./terraform/scripts/sync-local-state.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"
# Load the Terraform helpers.
# shellcheck source=tf-lib.sh
source "${ROOT_DIR}/terraform/scripts/tf-lib.sh"

# Announce the step.
step "Check that .state does not belong to the shell example"
# The shell scripts never set STATE_OWNER; a state file without it is theirs.
if [[ -s "${STATE_FILE}" && "${STATE_OWNER:-}" != "terraform" ]]; then fail "${STATE_DIR} was created by the shell scripts. Use a second copy of this project for the Terraform example."; fi
# Mark the folder as ours.
state_set STATE_OWNER "terraform"

# Announce the step.
step "Layer 1: kubeconfig, addresses and registry"
# The public IP tells us whether layer 1 was applied at all.
public_ip="$(tf_output 01-infra public_ip_address)"
# Without it there is nothing to copy.
[[ -n "${public_ip}" ]] || fail "Layer 01-infra has no outputs yet. Apply it first."
# Write the kubeconfig; umask 077 makes the new file readable for you alone.
(umask 077 && "${TF_BIN}" -chdir="${TF_DIR}/01-infra" output -raw kube_config_raw > "${KUBECONFIG}")
# Address of the ingress gateway.
state_set PUBLIC_IP "${public_ip}"
# Base of the three host names.
state_set BASE_DOMAIN "$(tf_output 01-infra base_domain)"
# Registry name, for the image build script.
state_set ACR_NAME "$(tf_output 01-infra acr_name)"
# Registry address, for the image names.
state_set ACR_LOGIN_SERVER "$(tf_output 01-infra acr_login_server)"

# Announce the step.
step "Layer 2: CA certificate and Istio version (skipped when not applied yet)"
# The CA certificate lets curl and the tools trust the gateway.
ca_certificate="$(tf_output 02-platform ca_certificate_pem)"
# Only write the file when the layer has produced a certificate.
if [[ -n "${ca_certificate}" ]]; then printf '%s\n' "${ca_certificate}" > "${TLS_DIR}/ca.crt"; state_set ISTIO_ACTIVE_VERSION "$(tf_output 02-platform istio_active_version)"; fi

# Announce the step.
step "Layer 3: passwords and active database (skipped when not applied yet)"
# Password of alice, bob and carol.
test_password="$(tf_output 03-workloads test_user_password)"
# Only store values when the layer has produced them. kv_set writes to the
# private secrets file; nothing is printed.
if [[ -n "${test_password}" ]]; then
  # Test users.
  kv_set "${SECRETS_FILE}" TEST_USER_PASSWORD "${test_password}"
  # Keycloak administrator.
  kv_set "${SECRETS_FILE}" KEYCLOAK_ADMIN_PASSWORD "$(tf_output 03-workloads keycloak_admin_password)"
  # The PostgreSQL instance behind the Service "postgres".
  state_set POSTGRES_ACTIVE_RELEASE "$(tf_output 03-workloads postgres_active_release)"
fi

# Final message.
ok "local state is in sync. For kubectl: export KUBECONFIG=${KUBECONFIG}"
