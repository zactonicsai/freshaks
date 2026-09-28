#!/usr/bin/env bash
# =============================================================================
#  07-build-images.sh — build the Java store, Python deli and Go inspector
#  images IN THE CLOUD with 'az acr build' (no local Docker needed).
#  Bump IMAGE_TAG in 00-config.sh when you change code.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd az
need_generated ACR_NAME

build() { # name, folder
  step "az acr build ${1}:${IMAGE_TAG}  (from ${2})"
  az acr build --registry "$ACR_NAME" --image "freshmart/${1}:${IMAGE_TAG}" "$ROOT_DIR/$2" --output table
}

ONLY="${1:-all}"
[[ "$ONLY" == "all" || "$ONLY" == "java"   ]] && build java-store  apps/java-grocery-app
[[ "$ONLY" == "all" || "$ONLY" == "python" ]] && build python-deli apps/python-deli-app
[[ "$ONLY" == "all" || "$ONLY" == "go"     ]] && build go-client   tests/go-client

log "Images pushed to ${REGISTRY}/freshmart/*:${IMAGE_TAG}. Next: scripts/08-deploy-apps.sh"
log "Tip: './07-build-images.sh java' rebuilds just one image."
