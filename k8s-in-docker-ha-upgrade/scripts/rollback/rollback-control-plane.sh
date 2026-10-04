#!/usr/bin/env bash
# =============================================================================
# rollback-control-plane.sh — put the Kubernetes control plane back on the
# version it ran before 20-k8s-upgrade-control-plane.sh.
# Kubernetes has no "downgrade": a newer control plane rewrites what is
# stored in its database. The only way back is the backup that script 20 took
# while the server was stopped:
#   1. stop the server
#   2. replace its data with the backup (database, certificates, token)
#   3. start the server with the OLD image
# Only possible while the worker nodes still run the old version - nodes may
# never be newer than the control plane.
# COST: every change made in the cluster after the backup is forgotten.
# This is a last resort. On a managed service (AKS, EKS, GKE) it does not
# exist at all - which is why you test upgrades before you run them.
# Usage: ./scripts/rollback/rollback-control-plane.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# The upgrade script recorded the backup file ...
require_state K8S_CONTROL_PLANE_BACKUP "scripts/upgrade/20-k8s-upgrade-control-plane.sh"
# ... and the version it belongs to.
require_state K8S_CONTROL_PLANE_ROLLBACK_VERSION "scripts/upgrade/20-k8s-upgrade-control-plane.sh"
# The version to go back to.
old="${K8S_CONTROL_PLANE_ROLLBACK_VERSION}"
# Already there: done.
if [[ "${K8S_SERVER_VERSION}" == "${old}" ]]; then ok "the control plane already runs ${old}"; exit 0; fi
# The backup file must exist.
[[ -s "${K8S_CONTROL_PLANE_BACKUP}" ]] || fail "The backup ${K8S_CONTROL_PLANE_BACKUP} is missing."

# Announce the step.
step "Check that no worker node is newer than ${old}"
# Compare the minor version of every worker with the one we go back to.
for node in "${AGENT_LIST[@]}"; do
  # Name of the state key, e.g. K8S_AGENT_1_VERSION.
  key="$(node_version_key "${node}")"
  # A node that was already upgraded would be newer than the control plane.
  if [[ "$(k8s_minor_of "${!key}")" != "$(k8s_minor_of "${old}")" ]]; then fail "Node ${node} already runs ${!key}. The control plane cannot go back below its nodes."; fi
done
# Report success.
ok "all worker nodes still run Kubernetes $(k8s_minor_of "${old}")"
# Ask before destroying data.
confirm "Restore the control plane from ${K8S_CONTROL_PLANE_BACKUP} and start ${old}? Changes made in the cluster since that backup are lost." || fail "stopped by user"

# Announce the step.
step "Stop the control plane"
# Running pods on the worker nodes are not affected.
run docker compose stop server

# Announce the step.
step "Replace the server's data with the backup"
# A throwaway container mounts the server's volume, removes the current
# "server" folder (database, certificates) and the "agent" folder (downloaded
# images and run-time state of the newer version, re-created on start), and
# unpacks the backup that arrives on standard input.
info "restoring ${K8S_CONTROL_PLANE_BACKUP} into volume ${PROJECT_NAME}-server-data"
# --user 0: the files in the volume belong to root. --entrypoint sh: run a shell.
docker run --rm -i --user 0 --volume "${PROJECT_NAME}-server-data:/data" --entrypoint sh "${TOOLS_IMAGE}" -c 'rm -rf /data/server /data/agent && tar -xf - -C /data' < "${K8S_CONTROL_PLANE_BACKUP}"

# Announce the step.
step "Start the control plane with ${old}"
# Record the old version ...
state_set K8S_SERVER_VERSION "${old}"
# ... and write it into .env for docker-compose.yml.
write_compose_env
# Compose replaces the server container with one that uses the old image.
run docker compose up -d --no-deps server
# Wait until the API answers again.
wait_api_ready 300
# Wait until the server node reports the old version.
wait_node_version server "${old}" 300
# The worker nodes reconnect on their own.
run kubectl wait --for=condition=Ready node --all --timeout=300s

# Announce the step.
step "Check the result"
# All nodes on the old version again.
run kubectl get nodes --label-columns topology.kubernetes.io/zone
# Wait until every workload is complete.
wait_workloads_ready
# The services must still answer.
bash "${ROOT_DIR}/scripts/install/10-smoke-test.sh"
