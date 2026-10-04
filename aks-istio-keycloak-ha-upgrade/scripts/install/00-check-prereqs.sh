#!/usr/bin/env bash
# =============================================================================
# 00-check-prereqs.sh — check that every program the scripts need is installed.
# Changes nothing. Run it first; it tells you what is missing.
# Usage: ./scripts/install/00-check-prereqs.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Announce the first step (it is also written to logs/steps.log).
step "Check that the required programs are installed"
# Azure CLI: creates and upgrades the Azure resources.
require_cmd az "Install it from https://learn.microsoft.com/cli/azure/install-azure-cli"
# kubectl: talks to the Kubernetes API.
require_cmd kubectl "Install it with: az aks install-cli"
# Helm: installs the charts.
require_cmd helm "Install it from https://helm.sh/docs/intro/install/"
# openssl: creates the TLS certificate and the random passwords.
require_cmd openssl "Install OpenSSL with your package manager."
# curl: used by the smoke tests and the availability probe.
require_cmd curl "Install curl with your package manager."
# Docker is only needed when the images are built on this machine.
if [[ "${USE_ACR_BUILD}" != "true" ]]; then require_cmd docker "Install Docker, or set USE_ACR_BUILD=true to build inside Azure instead."; fi

# Announce the next step.
step "Show the versions that were found"
# Azure CLI version (2.60 or newer is recommended).
run az version --output table
# kubectl version. Keep kubectl within one minor version of the cluster; for
# this example (Kubernetes 1.34 to 1.36) kubectl 1.35 fits every stage.
run kubectl version --client
# Helm version. Helm 3 and Helm 4 both work; the scripts adapt to either.
run helm version --short
# OpenSSL (or LibreSSL on macOS) version.
run openssl version

# Announce the next step.
step "Check that 'sort -V' understands version numbers"
# The upgrade scripts sort versions such as 1.9 and 1.10; plain text sorting
# would put 1.10 first, "sort -V" must put 1.9 first.
[[ "$(printf '1.10\n1.9\n' | sort -V | head -n 1)" == "1.9" ]] || fail "Your 'sort' has no working -V option. Install GNU coreutils."
# Report success.
ok "sort -V works"

# Docker must not only be installed, its engine must also be running.
if [[ "${USE_ACR_BUILD}" != "true" ]]; then
  # Announce the step.
  step "Check that the Docker engine is running"
  # "docker info" fails when the engine cannot be reached.
  docker info >/dev/null 2>&1 || fail "Docker is installed but not running. Start Docker, or set USE_ACR_BUILD=true."
  # Report success.
  ok "Docker engine is running"
fi

# Announce the last step.
step "Show the settings that the other scripts will use"
# Where and under which names the Azure resources are created.
info "PREFIX=${PREFIX}  LOCATION=${LOCATION}  RESOURCE_GROUP=${RESOURCE_GROUP}  AKS_NAME=${AKS_NAME}"
# Cluster size (drives cost and vCPU quota).
info "system pool: ${SYSTEM_NODE_COUNT} x ${SYSTEM_NODE_SIZE}   user pool: ${USER_NODE_COUNT} x ${USER_NODE_SIZE}   zones: ${ZONES}"
# Old versions that will be installed.
info "install: Kubernetes ${K8S_VERSION_OLD}, Istio ${ISTIO_VERSION_OLD}, Keycloak ${KEYCLOAK_VERSION_OLD}, PostgreSQL ${POSTGRES_VERSION_OLD}, apps ${APP_VERSION_OLD}"
# Versions the upgrade scripts will move to.
info "upgrade: Kubernetes ${K8S_UPGRADE_PATH}, Istio ${ISTIO_UPGRADE_PATH}, Keycloak ${KEYCLOAK_VERSION_NEW}, PostgreSQL ${POSTGRES_VERSION_NEW}, apps ${APP_VERSION_NEW}"
# Storage backend for the shared volumes.
info "storage backend: ${STORAGE_BACKEND} (shared StorageClass: ${SHARED_STORAGE_CLASS})"
