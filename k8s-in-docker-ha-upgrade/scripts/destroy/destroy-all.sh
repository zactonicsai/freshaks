#!/usr/bin/env bash
# =============================================================================
# destroy-all.sh — remove the whole example from this machine: all containers,
# the Docker network, all volumes (cluster data, NFS disk, registry contents)
# and the local state (.env, .state).
# With --keep-images the two registry volumes are kept, so the next install
# does not have to download and build everything again.
# The logs/ folder is kept either way. Images that Docker itself downloaded
# (K3s, HAProxy, ...) stay in Docker's image cache; "docker image prune -a"
# removes them if you want the disk space back.
# Usage: ./scripts/destroy/destroy-all.sh [--keep-images]
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Ask before deleting everything.
confirm "DESTROY the example cluster and all its data on this machine?" || fail "stopped by user"

# Compose can only read docker-compose.yml together with the generated .env.
if [[ -f .env ]]; then
  # Announce the step.
  step "Stop and remove all containers and the network"
  # Keep the registry volumes when asked to, remove everything otherwise.
  if [[ "${1:-}" == "--keep-images" ]]; then
    # Containers and network only; volumes are handled one by one below.
    run docker compose down --remove-orphans
    # Remove every volume of the project except the two registry volumes.
    for volume in $(docker volume ls --quiet --filter "name=${PROJECT_NAME}-"); do
      # Skip the local registry and the Docker Hub cache.
      if [[ "${volume}" == "${PROJECT_NAME}-registry-data" || "${volume}" == "${PROJECT_NAME}-hub-cache-data" ]]; then info "keeping volume ${volume}"; continue; fi
      # Delete the volume and its data.
      run docker volume rm "${volume}"
    done
  else
    # --volumes also deletes the named volumes.
    run docker compose down --volumes --remove-orphans
  fi
else
  # Nothing was ever started from this folder.
  info "no .env file - the cluster was never started from this folder"
fi

# Announce the step.
step "Remove the local state"
# The generated settings for docker compose.
rm -f .env
# Passwords, certificates, kubeconfig, backups, remembered versions. The log
# pipe of this very script lives in .state, but it is already unlinked, so
# the folder can go.
rm -rf "${STATE_DIR}"
# Final message.
ok "the example is removed. Log files are kept in ${LOG_DIR}/"
