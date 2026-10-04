#!/usr/bin/env bash
# =============================================================================
# build-images.sh — build the two application images and push them to the
# registry that Terraform created. Run it after layer 1 and before layer 3,
# and again with the new tag before you change app_version.
# Usage: ./terraform/scripts/build-images.sh [TAG]     (default: 1.0.0)
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"

# Image tag: first argument, or the old application version.
tag="${1:-${APP_VERSION_OLD}}"

# Copy registry name and address from Terraform into .state.
run_script ../terraform/scripts/sync-local-state.sh
# The normal build script reads them from there.
run_script install/21-build-push-images.sh "${tag}"
