#!/usr/bin/env bash
# =============================================================================
# show-status.sh — one look at everything: versions, nodes, Helm releases,
# pods, Istio proxies, budgets, volumes, addresses and test logins.
# It changes nothing. The passwords are written to your terminal only, not
# into the log file.
# Usage: ./scripts/tools/show-status.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster

# Announce the step.
step "Containers of the cluster"
# One line per container with its image (= version) and state.
run docker compose ps

# Announce the step.
step "Versions remembered by the scripts"
# Active versions, rollback points and so on.
run cat "${STATE_FILE}"

# Announce the step.
step "Nodes: Kubernetes version and zone"
# The VERSION column changes node by node during a Kubernetes upgrade.
run kubectl get nodes --label-columns topology.kubernetes.io/zone

# Announce the step.
step "Helm releases in all namespaces"
# Chart versions and revision numbers.
run helm list --all-namespaces

# Announce the step.
step "Pods of the example"
# Namespace by namespace, with the node each pod runs on.
for namespace in istio-system istio-ingress istio-egress nfs-storage postgres keycloak apps; do
  # --output wide adds the node name.
  run kubectl --namespace "${namespace}" get pods --output wide
done

# Announce the step.
step "Istio proxy version of every pod in the mesh"
# namespace, pod, proxy image.
mesh_proxy_report

# Announce the step.
step "Where the revision tag points"
# The tag webhook carries the revision in its istio.io/rev label.
run kubectl get mutatingwebhookconfigurations --label-columns istio.io/rev,istio.io/tag

# Announce the step.
step "PodDisruptionBudgets and volumes"
# ALLOWED DISRUPTIONS must be at least 1 for a node drain to work.
run kubectl get poddisruptionbudgets --all-namespaces
# The NFS-backed claims.
run kubectl get persistentvolumeclaims --all-namespaces

# Announce the step.
step "Addresses and test logins"
# First application.
info "Portal   (app1): https://app1.${PUBLIC_DOMAIN}"
# Second application.
info "Reports  (app2): https://app2.${PUBLIC_DOMAIN}"
# Keycloak admin console.
info "Keycloak admin : https://keycloak.${PUBLIC_DOMAIN}/admin/"
# Why the browser shows a warning and how to get rid of it.
info "The certificate is signed by a private CA. Import ${TLS_DIR}/ca.crt as a trusted authority, or accept the browser warning for all three host names."
# What to do when a browser does not resolve *.localhost by itself.
info "If a name does not resolve, add this line to your hosts file: 127.0.0.1 app1.${BASE_DOMAIN} app2.${BASE_DOMAIN} keycloak.${BASE_DOMAIN}"
# The three users of realm "demo".
info "users: alice (roles user + admin), bob (role user), carol (role user)"
# Where the passwords are stored.
info "passwords are in ${SECRETS_FILE} (TEST_USER_PASSWORD, KEYCLOAK_ADMIN_PASSWORD)"
# Give the log writer a moment to print the lines above first.
sleep 1
# Write the passwords straight to the terminal (/dev/tty), bypassing the log.
# When there is no terminal (for example in a CI job) nothing is printed.
{
  # Empty line.
  printf '\n'
  # Password shared by alice, bob and carol.
  printf '  test users   alice / bob / carol   password: %s\n' "${TEST_USER_PASSWORD:-<not created yet>}"
  # Login for the Keycloak admin console.
  printf '  Keycloak     admin                 password: %s\n' "${KEYCLOAK_ADMIN_PASSWORD:-<not created yet>}"
  # Empty line.
  printf '\n'
  # The redirect sends the block to the terminal; if that fails, say so in the log.
} 2>/dev/null > /dev/tty || info "no terminal attached - passwords not shown"
