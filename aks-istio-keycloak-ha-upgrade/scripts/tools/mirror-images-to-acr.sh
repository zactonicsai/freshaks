#!/usr/bin/env bash
# =============================================================================
# mirror-images-to-acr.sh — optional: copy the PostgreSQL and Keycloak images
# into your own Azure Container Registry.
# Why: public registries limit how often you may pull, and they can be down
# exactly when a node upgrade restarts all pods. Images in your own registry
# are always there. This is a production best practice, not needed for a demo.
# Usage: ./scripts/tools/mirror-images-to-acr.sh
#        Optional for Docker Hub: DOCKERHUB_USERNAME=... DOCKERHUB_TOKEN=... (avoids pull limits)
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# The registry must exist.
require_state ACR_NAME "scripts/install/03-create-acr.sh"
# Its address is needed for the hints at the end.
require_state ACR_LOGIN_SERVER "scripts/install/03-create-acr.sh"

# Copy one image from a public registry into ACR.
import_image() {
  # $1 = source image, $2 = name and tag inside our registry.
  local source="$1" target="$2"
  # Announce the step.
  step "Import ${source} as ${target}"
  # "az acr import" copies registry-to-registry inside Azure; nothing is
  # downloaded to this machine. --force overwrites an existing tag.
  if [[ "${source}" == docker.io/* && -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_TOKEN:-}" ]]; then
    # With a Docker Hub login (not logged: the command line holds the token).
    az acr import --name "${ACR_NAME}" --source "${source}" --image "${target}" --force --username "${DOCKERHUB_USERNAME}" --password "${DOCKERHUB_TOKEN}"
  else
    # Anonymous import.
    run az acr import --name "${ACR_NAME}" --source "${source}" --image "${target}" --force
  fi
}

# PostgreSQL, old and new version (official image on Docker Hub).
import_image "docker.io/library/postgres:${POSTGRES_VERSION_OLD}" "mirror/postgres:${POSTGRES_VERSION_OLD}"
# New PostgreSQL version.
import_image "docker.io/library/postgres:${POSTGRES_VERSION_NEW}" "mirror/postgres:${POSTGRES_VERSION_NEW}"
# Keycloak, old and new version (official image on quay.io).
import_image "quay.io/keycloak/keycloak:${KEYCLOAK_VERSION_OLD}" "mirror/keycloak:${KEYCLOAK_VERSION_OLD}"
# New Keycloak version.
import_image "quay.io/keycloak/keycloak:${KEYCLOAK_VERSION_NEW}" "mirror/keycloak:${KEYCLOAK_VERSION_NEW}"

# Announce the step.
step "How to use the mirrored images"
# The deploy functions read these two variables (see config/env.sh).
info "export POSTGRES_IMAGE_REPOSITORY=${ACR_LOGIN_SERVER}/mirror/postgres"
# Same for Keycloak.
info "export KEYCLOAK_IMAGE_REPOSITORY=${ACR_LOGIN_SERVER}/mirror/keycloak"
# Istio: the image registry differs between Istio releases, so look it up.
info "Istio: run 'helm show values istio/istiod --version <version> | grep hub' to see the registry, import 'pilot' and 'proxyv2' for every version on your upgrade path the same way, then export ISTIO_HUB=${ACR_LOGIN_SERVER}/mirror/istio"
