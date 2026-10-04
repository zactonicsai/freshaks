#!/usr/bin/env bash
# =============================================================================
# 21-build-push-images.sh — build the images of the two Spring Boot apps and
# push them to the Azure Container Registry.
# Usage: ./scripts/install/21-build-push-images.sh [TAG]
#        TAG defaults to APP_VERSION_OLD; the upgrade passes APP_VERSION_NEW.
# Set USE_ACR_BUILD=true to build inside Azure when you have no local Docker.
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# The registry must exist.
require_state ACR_NAME "scripts/install/03-create-acr.sh"
# Its address is needed for the image names.
require_state ACR_LOGIN_SERVER "scripts/install/03-create-acr.sh"

# Image tag: first argument, or the old application version.
tag="${1:-${APP_VERSION_OLD}}"

# Build both applications, one after the other.
for app in app1 app2; do
  # Full image name, e.g. myacr.azurecr.io/app1:1.0.0
  image="${ACR_LOGIN_SERVER}/${app}:${tag}"
  # Two ways to build; pick by USE_ACR_BUILD from config/env.sh.
  if [[ "${USE_ACR_BUILD}" == "true" ]]; then
    # Announce the step.
    step "Build ${image} inside Azure (ACR Tasks)"
    # Uploads the source folder, builds it in Azure and stores the image in
    # the registry. --build-arg bakes the version number into the image.
    run az acr build --registry "${ACR_NAME}" --image "${app}:${tag}" --platform linux/amd64 --build-arg "APP_VERSION=${tag}" "${ROOT_DIR}/apps/${app}"
  else
    # Announce the step.
    step "Build ${image} with Docker"
    # --platform linux/amd64: the AKS nodes are x86-64. Without it an Apple
    # Silicon Mac would build an arm64 image that cannot start on the nodes.
    run docker build --platform linux/amd64 --build-arg "APP_VERSION=${tag}" --tag "${image}" "${ROOT_DIR}/apps/${app}"
  fi
done

# Locally built images still have to be uploaded.
if [[ "${USE_ACR_BUILD}" != "true" ]]; then
  # Announce the step.
  step "Sign Docker in to the registry"
  # Uses your Azure login; no registry password is needed.
  run az acr login --name "${ACR_NAME}"
  # Upload both images.
  for app in app1 app2; do
    # Announce the step.
    step "Push ${ACR_LOGIN_SERVER}/${app}:${tag}"
    # Uploads the image layers to the registry.
    run docker push "${ACR_LOGIN_SERVER}/${app}:${tag}"
  done
fi

# Announce the step.
step "Show the tags that are now in the registry"
# Lists all tags of application 1.
run az acr repository show-tags --name "${ACR_NAME}" --repository app1 --output table
# Lists all tags of application 2.
run az acr repository show-tags --name "${ACR_NAME}" --repository app2 --output table
