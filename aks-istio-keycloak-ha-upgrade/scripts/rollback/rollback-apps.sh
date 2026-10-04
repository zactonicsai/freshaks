#!/usr/bin/env bash
# =============================================================================
# rollback-apps.sh — put the two applications back to the version that ran
# before the last 50-apps-upgrade.sh, with "helm rollback".
# This is a rolling update in the other direction: no downtime.
# Usage: ./scripts/rollback/rollback-apps.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The Helm revisions recorded by the upgrade script must be known.
require_state APP1_ROLLBACK_REVISION "scripts/upgrade/50-apps-upgrade.sh"
# Same for the second application.
require_state APP2_ROLLBACK_REVISION "scripts/upgrade/50-apps-upgrade.sh"
# The old image tag (used when Helm no longer has the old revision).
require_state APP_ROLLBACK_TAG "scripts/upgrade/50-apps-upgrade.sh"
# The host names are needed for the check at the end.
require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"
# The public address too.
require_state PUBLIC_IP "scripts/install/04-create-public-ip.sh"

# Ask before changing anything.
confirm "Roll the applications back to version ${APP_ROLLBACK_TAG} (Helm revisions ${APP1_ROLLBACK_REVISION} and ${APP2_ROLLBACK_REVISION})?" || fail "stopped by user"

# Announce the step.
step "Show the release history of app1"
# Each line is one revision; the rollback adds a new line on top.
run helm history app1 --namespace apps --max 5

# Announce the step.
step "Roll back app1 to revision ${APP1_ROLLBACK_REVISION}"
# Helm re-applies the manifest of that revision and waits for the pods.
# Helm only keeps the last 10 revisions of a release; when the recorded one
# is gone, deploy the old image tag with the normal deploy function instead.
if ! run helm rollback app1 "${APP1_ROLLBACK_REVISION}" --namespace apps --wait --timeout "${HELM_TIMEOUT}"; then
  # Tell the user why the second way is used.
  warn "helm rollback did not work - deploying app1 ${APP_ROLLBACK_TAG} again instead"
  # Same result: the old image, rolled out pod by pod.
  deploy_app app1 "${APP_ROLLBACK_TAG}"
fi

# Announce the step.
step "Roll back app2 to revision ${APP2_ROLLBACK_REVISION}"
# Same for the second application.
if ! run helm rollback app2 "${APP2_ROLLBACK_REVISION}" --namespace apps --wait --timeout "${HELM_TIMEOUT}"; then
  # Tell the user why the second way is used.
  warn "helm rollback did not work - deploying app2 ${APP_ROLLBACK_TAG} again instead"
  # Same result: the old image, rolled out pod by pod.
  deploy_app app2 "${APP_ROLLBACK_TAG}"
fi

# The old tag is the active one again.
state_set APP_ACTIVE_TAG "${APP_ROLLBACK_TAG}"

# Announce the step.
step "Show which version answers"
# /api/info returns the version that is baked into the image.
curl_mesh "https://app1.${BASE_DOMAIN}/api/info"
# Line break after the JSON.
echo
# Same for application 2.
curl_mesh "https://app2.${BASE_DOMAIN}/api/info"
# Line break after the JSON.
echo
