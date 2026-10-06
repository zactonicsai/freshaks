#!/usr/bin/env bash
# 90-destroy.sh [--all] - deletes the kind cluster and the FreeIPA container. --all also deletes FreeIPA's data and the work/ folder.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init destroy "$@"
need docker kind
confirm "This deletes kind cluster '$CLUSTER_NAME' and container '$IPA_CONTAINER'." DESTROY
kind delete cluster --name "$CLUSTER_NAME" || true
docker rm -f "$IPA_CONTAINER" >/dev/null 2>&1 || true
if [ "${1:-}" = --all ]; then
  docker volume rm "$IPA_VOLUME" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
  ok "FreeIPA data volume and work/ are gone too"
else
  log "kept: Docker volume $IPA_VOLUME (FreeIPA data) and work/. Use --all to remove them."
fi
log "kept on purpose: logs/ and state/ (your records)"
