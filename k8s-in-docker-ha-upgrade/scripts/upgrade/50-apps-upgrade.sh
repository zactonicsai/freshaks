#!/usr/bin/env bash
# =============================================================================
# 50-apps-upgrade.sh — rolling update of both applications to a new image.
# The chart starts one new pod, waits until it is ready, then stops one old
# pod (maxUnavailable 0). Users notice nothing, or are signed in again
# automatically when "their" pod is replaced.
# Build and push the image first: ./scripts/install/08-build-image.sh 2.0.0
# Usage: ./scripts/upgrade/50-apps-upgrade.sh [TAG]   (default: APP_VERSION_NEW)
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# The running version must be known.
require_state APP_ACTIVE_VERSION "scripts/install/09-deploy-apps.sh"
# Target: first argument, or the new version from config/versions.env.
tag="${1:-${APP_VERSION_NEW}}"
# Already there: done.
if [[ "${APP_ACTIVE_VERSION}" == "${tag}" ]]; then ok "the applications already run ${tag}"; exit 0; fi

# Announce the step.
step "Check that image demo-app:${tag} is in the registry"
# The registry lists the tags of a repository as JSON; grep looks for "<tag>".
in_tools curl --silent --fail http://registry:5000/v2/demo-app/tags/list | grep -q "\"${tag}\"" || fail "Image demo-app:${tag} is not in the registry. Run: ./scripts/install/08-build-image.sh ${tag}"
# Report success.
ok "the image exists"

# Announce the step.
step "Remember the way back"
# Helm revision of app1 that runs right now.
app1_revision="$(helm_revision app1 apps)"
# Same for app2.
app2_revision="$(helm_revision app2 apps)"
# Without them "helm rollback" has no target.
[[ -n "${app1_revision}" && -n "${app2_revision}" ]] || fail "Could not read the Helm revisions of app1 and app2. Check: scripts/tools/in-tools.sh helm history app1 --namespace apps"
# Store them for rollback-apps.sh.
state_set APP1_ROLLBACK_REVISION "${app1_revision}"
# Same for app2.
state_set APP2_ROLLBACK_REVISION "${app2_revision}"
# And the version that goes with them.
state_set APP_ROLLBACK_VERSION "${APP_ACTIVE_VERSION}"

# Announce the step.
step "Rolling update of app1 to ${tag}"
# If the new pods never become ready, Helm puts the old version back by itself.
deploy_app app1 "${tag}"
# Announce the step.
step "Rolling update of app2 to ${tag}"
# Same chart, other values file.
deploy_app app2 "${tag}"
# Remember the new version.
state_set APP_ACTIVE_VERSION "${tag}"

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
# Explain the way back.
info "Way back: scripts/rollback/rollback-apps.sh"
