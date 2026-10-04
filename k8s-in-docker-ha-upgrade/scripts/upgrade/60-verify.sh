#!/usr/bin/env bash
# =============================================================================
# 60-verify.sh — after the upgrade: is every component really on its target
# version, and does everything still work? It changes nothing.
# Usage: ./scripts/upgrade/60-verify.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# The active database must be known.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/06-install-postgres.sh"
# Number of components that are not on their target version.
mismatches=0
# Compare a running version with the expected one and count mismatches.
check_version() {
  # $1 = what, $2 = running, $3 = expected.
  if [[ "$2" == "$3" ]]; then ok "$1: $2"; else warn "$1: running '$2', expected '$3'"; mismatches=$((mismatches + 1)); fi
}
# The last entry of each upgrade path is the target ("##* " cuts everything
# up to the last space).
k8s_target="$(k3s_node_version "${K8S_UPGRADE_PATH##* }")"
# Newest Istio version on the path.
istio_target="${ISTIO_UPGRADE_PATH##* }"

# Announce the step.
step "Kubernetes"
# Column 5 of "kubectl get nodes" is the version; count nodes on another one.
behind="$(kubectl get nodes --no-headers | awk -v wanted="${k8s_target}" '$5 != wanted' | wc -l | tr -d ' ')"
# All four nodes must match.
check_version "nodes not on ${k8s_target}" "${behind}" "0"
# Show them.
run kubectl get nodes --label-columns topology.kubernetes.io/zone

# Announce the step.
step "Istio"
# The version the tag points at.
check_version "active Istio version" "${ISTIO_ACTIVE_VERSION:-unknown}" "${istio_target}"
# Count proxies whose image is not the target version.
outdated="$(mesh_proxy_report | awk -v wanted=":${istio_target}" 'index($3, wanted) == 0' | wc -l | tr -d ' ')"
# Every sidecar and gateway must match.
check_version "proxies not on ${istio_target}" "${outdated}" "0"

# Announce the step.
step "Keycloak"
# Image of the running Deployment, e.g. quay.io/keycloak/keycloak:26.8.0
keycloak_image="$(kubectl --namespace keycloak get deployment keycloak --output jsonpath='{.spec.template.spec.containers[0].image}')"
# "##*:" keeps only the tag after the last colon.
check_version "Keycloak image tag" "${keycloak_image##*:}" "${KEYCLOAK_VERSION_NEW}"

# Announce the step.
step "PostgreSQL"
# The server reports e.g. "18.6 (Debian 18.6-1.pgdg13+1)"; cut keeps the first word.
postgres_running="$(pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "SHOW server_version;" | cut -d' ' -f1)"
# Must be the new version.
check_version "PostgreSQL server version" "${postgres_running}" "${POSTGRES_VERSION_NEW}"

# Announce the step.
step "Applications"
# Ask each application for its version.
for app in app1 app2; do
  # sed pulls the value of "version" out of the JSON of /api/info.
  app_running="$(curl_mesh "https://${app}.${PUBLIC_DOMAIN}/api/info" | sed -E 's/.*"version":"([^"]*)".*/\1/')"
  # Must be the new version.
  check_version "${app} version" "${app_running}" "${APP_VERSION_NEW}"
done

# Announce the step.
step "Smoke test and login test"
# Public endpoints and access rules.
bash "${ROOT_DIR}/scripts/install/10-smoke-test.sh"
# Full login, single sign-on, shared volume, egress.
bash "${ROOT_DIR}/scripts/tools/test-login.sh"

# Announce the step.
step "Result"
# Any mismatch is an error.
if (( mismatches > 0 )); then fail "${mismatches} component(s) are not on their target version."; fi
# Everything is on target.
ok "all components run their target versions and all tests passed"
