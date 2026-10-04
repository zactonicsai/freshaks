#!/usr/bin/env bash
# =============================================================================
# install-all.sh — install the whole example with the OLD versions, by
# running the numbered scripts in order (10 to 20 minutes, mostly downloads).
# If a step fails, fix the cause and run this script (or just that step) again.
# Usage: ./scripts/install/install-all.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Docker, memory, settings.
run_script install/01-check-docker.sh
# The cluster: registries, four Kubernetes nodes, load balancer, tools.
run_script install/02-start-cluster.sh
# Namespaces, NFS server pod, shared volumes.
run_script install/03-install-storage.sh
# Istio control plane, revision tag, gateways.
run_script install/04-install-istio.sh
# Certificate, mutual TLS, authorization, egress, routes.
run_script install/05-apply-mesh-rules.sh
# PostgreSQL on NFS.
run_script install/06-install-postgres.sh
# Keycloak with the realm and the test users.
run_script install/07-install-keycloak.sh
# Build the application image and push it to the local registry.
run_script install/08-build-image.sh "${APP_VERSION_OLD}"
# Portal and Reports.
run_script install/09-deploy-apps.sh "${APP_VERSION_OLD}"
# Public endpoints and access rules.
run_script install/10-smoke-test.sh
# Full login, single sign-on, shared volume, egress.
run_script tools/test-login.sh
# Versions, pods, addresses and test logins.
run_script tools/show-status.sh
