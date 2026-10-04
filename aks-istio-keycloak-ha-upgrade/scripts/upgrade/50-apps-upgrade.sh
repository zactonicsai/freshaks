#!/usr/bin/env bash
# =============================================================================
# 50-apps-upgrade.sh — rolling upgrade of the two applications to a new image
# tag. Each app has two pods; Kubernetes starts a new pod, waits until it is
# ready, and only then stops an old one, so the apps stay available.
# Users are signed in again automatically (single sign-on) when their pod is
# replaced, because sessions are kept in the pod's memory.
# Usage: ./scripts/upgrade/50-apps-upgrade.sh [TAG]   (default: APP_VERSION_NEW)
#        Build the images first: ./scripts/install/21-build-push-images.sh TAG
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The running application version must be known.
require_state APP_ACTIVE_TAG "scripts/install/22-deploy-apps.sh"
# The registry is needed for the image check.
require_state ACR_NAME "scripts/install/03-create-acr.sh"
# The host names are needed for the check at the end.
require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"
# The public address too.
require_state PUBLIC_IP "scripts/install/04-create-public-ip.sh"

# Target tag: first argument, or the new version from config/versions.env.
tag="${1:-${APP_VERSION_NEW}}"
# Already there: nothing to do.
if [[ "${APP_ACTIVE_TAG}" == "${tag}" ]]; then ok "the applications already run ${tag}"; exit 0; fi

# Announce the step.
step "Check that both images with tag ${tag} are in the registry"
# Deploying a tag that does not exist would leave new pods in ImagePullBackOff.
for app in app1 app2; do
  # Lists the tags of the repository and looks for an exact match.
  az acr repository show-tags --name "${ACR_NAME}" --repository "${app}" --output tsv | grep -Fx "${tag}" >/dev/null || fail "Image ${app}:${tag} is not in the registry. Run: ./scripts/install/21-build-push-images.sh ${tag}"
done
# Report success.
ok "both images exist"

# Announce the step.
step "Remember the way back"
# Helm revision of app1 that runs right now.
app1_revision="$(helm_revision app1 apps)"
# Helm revision of app2 that runs right now.
app2_revision="$(helm_revision app2 apps)"
# Without both numbers there would be no way back: stop before changing anything.
[[ -n "${app1_revision}" && -n "${app2_revision}" ]] || fail "Could not read the Helm revisions of app1 and app2. Check: helm history app1 --namespace apps"
# Store them for scripts/rollback/rollback-apps.sh.
state_set APP1_ROLLBACK_REVISION "${app1_revision}"
# Same for the second application.
state_set APP2_ROLLBACK_REVISION "${app2_revision}"
# The old tag, for the record.
state_set APP_ROLLBACK_TAG "${APP_ACTIVE_TAG}"

# Announce the step.
step "Rolling upgrade of app1 to ${tag}"
# Helm changes the image tag; if the new pods do not become ready, Helm puts
# the old version back automatically.
deploy_app app1 "${tag}"

# Announce the step.
step "Rolling upgrade of app2 to ${tag}"
# Same for the second application.
deploy_app app2 "${tag}"

# The new tag is the active one now.
state_set APP_ACTIVE_TAG "${tag}"

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
