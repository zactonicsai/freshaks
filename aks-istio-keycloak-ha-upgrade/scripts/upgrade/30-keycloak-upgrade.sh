#!/usr/bin/env bash
# =============================================================================
# 30-keycloak-upgrade.sh — upgrade Keycloak to the new version.
# A Keycloak upgrade across major versions changes the database tables, and
# old and new Keycloak pods cannot share one cluster. So this is NOT a rolling
# update: stop all old pods, back up the database, start the new version.
# Logins are unavailable for a few minutes; users who are already signed in
# to the applications keep working.
# Usage: ./scripts/upgrade/30-keycloak-upgrade.sh [TARGET_VERSION]
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The running Keycloak version must be known.
require_state KEYCLOAK_ACTIVE_VERSION "scripts/install/20-install-keycloak.sh"
# The active PostgreSQL release must be known for the backup.
require_state POSTGRES_ACTIVE_RELEASE "scripts/install/19-install-postgres.sh"
# The host names are needed for the check at the end.
require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"
# The public address too.
require_state PUBLIC_IP "scripts/install/04-create-public-ip.sh"

# Target: first argument, or the new version from config/versions.env.
target="${1:-${KEYCLOAK_VERSION_NEW}}"
# Already there: nothing to do.
if [[ "${KEYCLOAK_ACTIVE_VERSION}" == "${target}" ]]; then ok "Keycloak already runs ${target}"; exit 0; fi

# Announce the step.
step "Remember the way back"
# The Helm revision that runs right now (old version, two pods).
rollback_revision="$(helm_revision keycloak keycloak)"
# Without a revision number there would be no way back: stop before changing anything.
[[ -n "${rollback_revision}" ]] || fail "Could not read the Helm revision of release 'keycloak'. Check: helm history keycloak --namespace keycloak"
# Store it for scripts/rollback/rollback-keycloak.sh.
state_set KEYCLOAK_ROLLBACK_REVISION "${rollback_revision}"
# Store the old version too.
state_set KEYCLOAK_ROLLBACK_VERSION "${KEYCLOAK_ACTIVE_VERSION}"

# Announce the step.
step "Stop Keycloak ${KEYCLOAK_ACTIVE_VERSION} (logins are unavailable from now on)"
# Scale to zero through Helm, so Helm's record matches the cluster. Stopping
# first guarantees that nothing writes to the database during the backup.
deploy_keycloak "${KEYCLOAK_ACTIVE_VERSION}" --set replicaCount=0
# Wait until the pods have really ended (they finish open requests first).
wait_pods_gone keycloak app.kubernetes.io/name=keycloak 300

# Announce the step.
step "Back up the database in its OLD format"
# The new version rewrites the tables on its first start, and that cannot be
# undone. This dump is the only way back to ${KEYCLOAK_ACTIVE_VERSION}.
pg_backup "before-keycloak-${target}"
# Store the file name for the rollback script.
state_set KEYCLOAK_ROLLBACK_DUMP "${LAST_PG_BACKUP}"

# Announce the step.
step "Start Keycloak ${target}"
# The values file for the new version is picked automatically (new option
# names). updateStrategy=Recreate makes sure old and new pods never overlap.
# The first new pod migrates the database; Helm waits until both are ready.
# If they do not become ready in time Helm puts the previous revision (zero
# pods) back - then run scripts/rollback/rollback-keycloak.sh.
deploy_keycloak "${target}" --set updateStrategy=Recreate
# The new version is the active one now.
state_set KEYCLOAK_ACTIVE_VERSION "${target}"

# Announce the step.
step "Switch back to rolling updates for everyday changes"
# Only the update strategy changes; the pods are not restarted.
deploy_keycloak "${target}"

# Announce the step.
step "Check that Keycloak answers and show the pods"
# The discovery document must be served again.
wait_http "keycloak discovery document" 200 300 "https://keycloak.${BASE_DOMAIN}/realms/demo/.well-known/openid-configuration"
# Two pods with the new image.
run kubectl --namespace keycloak get pods --output wide
# The image tag shows the version.
run kubectl --namespace keycloak get deployment keycloak --output jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
