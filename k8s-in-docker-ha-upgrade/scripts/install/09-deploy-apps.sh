#!/usr/bin/env bash
# =============================================================================
# 09-deploy-apps.sh — deploy the demo application twice with Helm:
#   app1 "Portal"  (light design)   and   app2 "Reports" (dark design)
# Same image, same chart; name, design and OIDC client differ
# (helm/values/app1.yaml and app2.yaml). Two pods each.
# Usage: ./scripts/install/09-deploy-apps.sh [TAG]     (default: 1.0.0)
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# The client secrets were generated together with Keycloak.
[[ -n "${APP1_CLIENT_SECRET:-}" && -n "${APP2_CLIENT_SECRET:-}" ]] || fail "No client secrets yet. Run scripts/install/07-install-keycloak.sh first."
# Image tag: first argument, else what is active, else the old version.
tag="${1:-${APP_ACTIVE_VERSION:-${APP_VERSION_OLD}}}"

# Announce the step.
step "Store the OIDC client secrets"
# One secret per application (piped in, never on a command line).
kubectl_stdin apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: app1-oidc
  namespace: apps
type: Opaque
stringData:
  client-secret: "${APP1_CLIENT_SECRET}"
---
apiVersion: v1
kind: Secret
metadata:
  name: app2-oidc
  namespace: apps
type: Opaque
stringData:
  client-secret: "${APP2_CLIENT_SECRET}"
YAML

# Announce the step.
step "Deploy app1 (Portal) ${tag}"
# Helm waits until both pods are ready.
deploy_app app1 "${tag}"
# Announce the step.
step "Deploy app2 (Reports) ${tag}"
# Same chart, other values file.
deploy_app app2 "${tag}"
# Remember which version is active.
state_set APP_ACTIVE_VERSION "${tag}"

# Announce the step.
step "Show the pods and the nodes they run on"
# The chart spreads the two pods of each app over different nodes.
run kubectl --namespace apps get pods --output wide
