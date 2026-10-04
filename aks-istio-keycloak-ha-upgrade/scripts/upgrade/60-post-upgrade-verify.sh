#!/usr/bin/env bash
# =============================================================================
# 60-post-upgrade-verify.sh — final check after the whole upgrade: compare
# what is running with the target versions in config/versions.env, then run
# the smoke test and a complete login. Changes nothing.
# Usage: ./scripts/upgrade/60-post-upgrade-verify.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The active PostgreSQL release must be known.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/19-install-postgres.sh"
# The host names are needed for the application check.
require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"
# The public address too.
require_state PUBLIC_IP "scripts/install/04-create-public-ip.sh"

# Number of differences found.
mismatches=0
# Compare one "running" value with its target and count differences.
check_version() {
  # $1 = what, $2 = running value, $3 = expected value.
  if [[ "$2" == "$3" ]]; then ok "$1: $2"; else warn "$1: running '$2', expected '$3'"; mismatches=$((mismatches + 1)); fi
}

# Announce the step.
step "Kubernetes"
# The last entry of the upgrade path is the target minor version.
check_version "control plane minor version" "$(k8s_server_minor)" "${K8S_UPGRADE_PATH##* }"
# Every node must run the same minor version as the control plane. Column 5 of
# "kubectl get nodes" is the kubelet version; count nodes on another minor.
behind="$(kubectl get nodes --no-headers | awk -v wanted="v${K8S_UPGRADE_PATH##* }." 'index($5, wanted) != 1' | wc -l | tr -d ' ')"
# Zero nodes may be behind.
check_version "nodes not on the target version" "${behind}" "0"

# Announce the step.
step "Istio"
# The active control plane must be the last entry of the Istio path.
check_version "active Istio version" "${ISTIO_ACTIVE_VERSION:-unknown}" "${ISTIO_UPGRADE_PATH##* }"
# No proxy may run another version.
outdated="$(mesh_proxy_report | awk -v wanted=":${ISTIO_UPGRADE_PATH##* }" 'index($3, wanted) == 0' | wc -l | tr -d ' ')"
# Zero proxies may be outdated.
check_version "proxies not on the target version" "${outdated}" "0"

# Announce the step.
step "Keycloak"
# Image of the Keycloak Deployment; "##*:" keeps the part after the last colon (the tag).
keycloak_image="$(kubectl --namespace keycloak get deployment keycloak --output jsonpath='{.spec.template.spec.containers[0].image}')"
# Compare the tag with the target version.
check_version "Keycloak image tag" "${keycloak_image##*:}" "${KEYCLOAK_VERSION_NEW}"

# Announce the step.
step "PostgreSQL"
# Ask the server behind the active release for its version, e.g. "18.6".
postgres_running="$(pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "SHOW server_version;" | cut -d' ' -f1)"
# Compare with the target version.
check_version "PostgreSQL server version" "${postgres_running}" "${POSTGRES_VERSION_NEW}"

# Announce the step.
step "Applications"
# The version is baked into the image and returned by /api/info.
for app in app1 app2; do
  # Cut the value of "version" out of the JSON answer.
  app_running="$(curl_mesh "https://${app}.${BASE_DOMAIN}/api/info" | sed -E 's/.*"version":"([^"]*)".*/\1/')"
  # Compare with the target version.
  check_version "${app} version" "${app_running}" "${APP_VERSION_NEW}"
done

# Announce the step.
step "Smoke test and login test"
# Public endpoints, redirects and access rules.
bash "${ROOT_DIR}/scripts/install/24-smoke-test.sh"
# Full OIDC login, single sign-on, shared volume and egress.
bash "${ROOT_DIR}/scripts/tools/test-login.sh"

# Announce the step.
step "Result"
# Any difference is an error.
if (( mismatches > 0 )); then fail "${mismatches} component(s) are not on their target version."; fi
# Everything matches.
ok "all components run their target versions and all tests passed"
