#!/usr/bin/env bash
# =============================================================================
# 08-build-image.sh — build the demo application with Docker and push the
# image to the local registry container.
# The version number is a build argument: 1.0.0 and 2.0.0 are built from the
# same sources (in real life the code would differ; the upgrade mechanics are
# the same).
# Usage: ./scripts/install/08-build-image.sh [TAG]     (default: 1.0.0)
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Image tag: first argument, or the old application version.
tag="${1:-${APP_VERSION_OLD}}"
# The registry as YOUR machine sees it (published port of the registry container).
image="localhost:${REGISTRY_PORT}/demo-app:${tag}"

# Announce the step.
step "Build ${image}"
# Two stages (see apps/demo-app/Dockerfile): Maven builds the jar, a small
# Java runtime image runs it. The image is built for the CPU type of this
# machine, which is also the CPU type of the Kubernetes nodes.
run docker build --build-arg "APP_VERSION=${tag}" --tag "${image}" apps/demo-app

# Announce the step.
step "Push the image to the local registry"
# Docker accepts a registry on "localhost" without TLS.
run docker push "${image}"
# Final message. Inside the cluster the same registry is called registry:5000
# (docker/k3s/registries.yaml), so pods use registry:5000/demo-app:<tag>.
ok "pushed. Pods will pull it as registry:5000/demo-app:${tag}"
