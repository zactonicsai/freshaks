#!/usr/bin/env bash
# =============================================================================
# rollback-apps.sh — put both applications back on the version they ran
# before 50-apps-upgrade.sh. This is the easy kind of rollback: the apps keep
# no data of their own, so "helm rollback" restores the old definition and
# Kubernetes replaces the pods one by one. Nobody is offline.
# Usage: ./scripts/rollback/rollback-apps.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# The upgrade script recorded the Helm revisions to go back to.
require_state APP1_ROLLBACK_REVISION "scripts/upgrade/50-apps-upgrade.sh"
# Same for app2.
require_state APP2_ROLLBACK_REVISION "scripts/upgrade/50-apps-upgrade.sh"
# And the version that goes with them.
require_state APP_ROLLBACK_VERSION "scripts/upgrade/50-apps-upgrade.sh"
# Ask before changing anything.
confirm "Roll the applications back to version ${APP_ROLLBACK_VERSION} (Helm revisions ${APP1_ROLLBACK_REVISION} and ${APP2_ROLLBACK_REVISION})?" || fail "stopped by user"

# Announce the step.
step "Show the release history of app1"
# The last five revisions with their status.
run helm history app1 --namespace apps --max 5

# Roll back both applications the same way.
for app in app1 app2; do
  # Pick the recorded revision of this application.
  if [[ "${app}" == "app1" ]]; then revision="${APP1_ROLLBACK_REVISION}"; else revision="${APP2_ROLLBACK_REVISION}"; fi
  # Announce the step.
  step "Roll back ${app} to revision ${revision}"
  # Helm keeps only its last 10 revisions. If the recorded one is gone,
  # deploying the old version again gives the same result.
  if ! run helm rollback "${app}" "${revision}" --namespace apps --wait --timeout "${HELM_TIMEOUT}"; then
    # Say what happens instead.
    warn "helm rollback did not work - deploying ${app} ${APP_ROLLBACK_VERSION} again instead"
    # Same chart, old image tag.
    deploy_app "${app}" "${APP_ROLLBACK_VERSION}"
  fi
done
# Remember which version is active again.
state_set APP_ACTIVE_VERSION "${APP_ROLLBACK_VERSION}"

# Announce the step.
step "Show which version answers"
# Prints the JSON of /api/info: application name, version and pod name.
curl_mesh "https://app1.${PUBLIC_DOMAIN}/api/info"
# Line break after the JSON.
echo
# Same for application 2.
curl_mesh "https://app2.${PUBLIC_DOMAIN}/api/info"
# Line break after the JSON.
echo
