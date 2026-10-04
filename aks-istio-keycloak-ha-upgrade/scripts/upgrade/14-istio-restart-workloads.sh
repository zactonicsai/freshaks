#!/usr/bin/env bash
# =============================================================================
# 14-istio-restart-workloads.sh — restart the workloads in the mesh so that
# they get the sidecar of the new Istio version.
# Keycloak and the apps have two pods each and are replaced one by one, so
# they stay available. PostgreSQL is one pod: the database is away for some
# seconds while it restarts.
# Usage: ./scripts/upgrade/14-istio-restart-workloads.sh
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

# Announce the step.
step "Restart PostgreSQL, Keycloak and the applications, one after the other"
# "kubectl rollout restart" replaces the pods using each workload's rolling
# update settings and waits until the new pods are ready.
restart_mesh_workloads

# Announce the step.
step "Show the proxy version of every pod"
# Columns: namespace, pod, proxy image.
mesh_proxy_report
