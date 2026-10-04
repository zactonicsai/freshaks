#!/usr/bin/env bash
# =============================================================================
# 30-keycloak-upgrade.sh — upgrade Keycloak across major versions (24 -> 26).
# Old and new Keycloak pods must never run together, and the new version
# changes the database tables on its first start. So this is NOT a rolling
# update:
#   1. remember the way back (Helm revision, old version)
#   2. stop all Keycloak pods     (logins are down from here ...)
#   3. dump the database in its OLD format - the only way back
#   4. start the new version; it migrates the database
#   5. switch back to rolling updates for everyday changes   (... to here)
# Users who are already signed in to the apps keep working during the pause.
# Usage: ./scripts/upgrade/30-keycloak-upgrade.sh [VERSION]   (default: KEYCLOAK_VERSION_NEW)
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
require_state KEYCLOAK_ACTIVE_VERSION "scripts/install/07-install-keycloak.sh"
# The active database must be known for the backup.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/06-install-postgres.sh"
# Target: first argument, or the new version from config/versions.env.
target="${1:-${KEYCLOAK_VERSION_NEW}}"
# Already there: done.
if [[ "${KEYCLOAK_ACTIVE_VERSION}" == "${target}" ]]; then ok "Keycloak already runs ${target}"; exit 0; fi
# Last chance to stop.
confirm "Upgrade Keycloak ${KEYCLOAK_ACTIVE_VERSION} -> ${target}? Logins will be unavailable for a few minutes." || fail "stopped by user"

# Announce the step.
step "Remember the way back"
# Number of the Helm revision that runs right now.
rollback_revision="$(helm_revision keycloak keycloak)"
# Without it "helm rollback" has no target.
[[ -n "${rollback_revision}" ]] || fail "Could not read the Helm revision of release 'keycloak'. Check: scripts/tools/in-tools.sh helm history keycloak --namespace keycloak"
# Store it for rollback-keycloak.sh.
state_set KEYCLOAK_ROLLBACK_REVISION "${rollback_revision}"
# And the version that goes with it.
state_set KEYCLOAK_ROLLBACK_VERSION "${KEYCLOAK_ACTIVE_VERSION}"

# Announce the step.
step "Stop Keycloak ${KEYCLOAK_ACTIVE_VERSION} (logins are unavailable from now on)"
# Scale to zero THROUGH HELM, so Helm's record matches what runs.
deploy_keycloak "${KEYCLOAK_ACTIVE_VERSION}" --set replicaCount=0
# Wait until the last pod is gone, so nothing writes to the database any more.
wait_pods_gone keycloak app.kubernetes.io/name=keycloak 300

# Announce the step.
step "Back up the database in its OLD format"
# Taken while Keycloak is stopped: exactly the state the old version understands.
pg_backup "before-keycloak-${target}"
# Store the file name for rollback-keycloak.sh.
state_set KEYCLOAK_ROLLBACK_DUMP "${LAST_PG_BACKUP}"

# Announce the step.
step "Start Keycloak ${target}"
# "Recreate" = never run old and new pods together. The first pod migrates the
# database; Helm waits until the pods are ready. Versions 25+ automatically get
# the values file with the new option names (see deploy_keycloak).
deploy_keycloak "${target}" --set updateStrategy=Recreate
# Remember the new version.
state_set KEYCLOAK_ACTIVE_VERSION "${target}"

# Announce the step.
step "Switch back to rolling updates for everyday changes"
# Same version, default strategy (RollingUpdate); the pods are not restarted.
deploy_keycloak "${target}"

# Announce the step.
step "Check that Keycloak answers and show the pods"
# The discovery document must be served again.
wait_http "keycloak discovery document" 200 300 "https://keycloak.${PUBLIC_DOMAIN}/realms/demo/.well-known/openid-configuration"
# Pods and nodes.
run kubectl --namespace keycloak get pods --output wide
# The image that runs now.
run kubectl --namespace keycloak get deployment keycloak --output jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# Explain the way back.
info "Way back: scripts/rollback/rollback-keycloak.sh (restores the dump ${KEYCLOAK_ROLLBACK_DUMP})"
