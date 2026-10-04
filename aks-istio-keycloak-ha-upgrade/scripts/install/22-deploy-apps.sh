#!/usr/bin/env bash
# =============================================================================
# 22-deploy-apps.sh — deploy the two Spring Boot applications with Helm
# (two pods each, OLD application version).
# Usage: ./scripts/install/22-deploy-apps.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster

# Announce the step.
step "Deploy app1 (Portal) version ${APP_VERSION_OLD}"
# Helm release "app1" in namespace apps.
deploy_app app1 "${APP_VERSION_OLD}"

# Announce the step.
step "Deploy app2 (Reports) version ${APP_VERSION_OLD}"
# Helm release "app2" in namespace apps.
deploy_app app2 "${APP_VERSION_OLD}"

# Remember which application version is running.
state_set APP_ACTIVE_TAG "${APP_VERSION_OLD}"

# Announce the step.
step "Show the application pods and their disruption budgets"
# Four pods; READY 2/2 means "application + Istio sidecar".
run kubectl --namespace apps get pods --output wide
# One budget per application.
run kubectl --namespace apps get poddisruptionbudget
