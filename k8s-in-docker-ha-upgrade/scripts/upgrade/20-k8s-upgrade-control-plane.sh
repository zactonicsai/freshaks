#!/usr/bin/env bash
# =============================================================================
# 20-k8s-upgrade-control-plane.sh — upgrade the Kubernetes control plane by
# one minor version. The worker nodes are NOT touched (script 21 does that).
#   1. checks: one minor version at a time, all nodes on the current version,
#      the active Istio supports the new Kubernetes version
#   2. stop the server container and copy its database and certificates away
#      (the way back, see rollback-control-plane.sh)
#   3. start the server again with the image of the new version
# While the server is away (about a minute) the Kubernetes API does not
# answer: nothing can be deployed or rescheduled. Running pods and their
# traffic are not affected - watch the availability probe.
# Usage: ./scripts/upgrade/20-k8s-upgrade-control-plane.sh [VERSION]
#        (default: the next version on K8S_UPGRADE_PATH)
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# The current version must be known.
require_state K8S_SERVER_VERSION "scripts/install/02-start-cluster.sh"
# Istio must be installed, because its version limits the Kubernetes version.
require_state ISTIO_ACTIVE_VERSION "scripts/install/04-install-istio.sh"
# Version the control plane runs now (an image tag such as v1.34.12-k3s1).
current="${K8S_SERVER_VERSION}"
# Target: first argument, or the next version on the upgrade path.
target="${1:-$(next_version "${current}" "${K8S_UPGRADE_PATH}")}"
# Nothing newer on the path: done.
if [[ -z "${target}" || "${target}" == "${current}" ]]; then ok "the control plane already runs ${current}, the newest version on the upgrade path"; exit 0; fi

# Announce the step.
step "Check the size of the hop: ${current} -> ${target}"
# Second number of the current version, e.g. 34.
current_minor="$(k8s_minor_of "${current}" | cut -d. -f2)"
# Second number of the target version, e.g. 35.
target_minor="$(k8s_minor_of "${target}" | cut -d. -f2)"
# Kubernetes has no downgrade.
if (( target_minor < current_minor )); then fail "${target} is older than ${current}. Kubernetes cannot be downgraded; see scripts/rollback/rollback-control-plane.sh."; fi
# One minor version at a time.
if (( target_minor - current_minor > 1 )); then fail "Kubernetes must be upgraded one minor version at a time. ${current} -> ${target} skips a version."; fi
# Report success.
ok "hop size is fine"

# Announce the step.
step "Check that every worker node has finished the previous upgrade"
# Nodes may be older than the control plane, but must not fall further behind.
for node in "${AGENT_LIST[@]}"; do
  # Name of the state key, e.g. K8S_AGENT_1_VERSION.
  key="$(node_version_key "${node}")"
  # A node on an older minor version must be upgraded first.
  if [[ "$(k8s_minor_of "${!key}")" != "$(k8s_minor_of "${current}")" ]]; then fail "Node ${node} still runs ${!key}. Finish the last upgrade first: scripts/upgrade/21-k8s-upgrade-node.sh ${node}"; fi
done
# Report success.
ok "all worker nodes run Kubernetes $(k8s_minor_of "${current}")"

# Announce the step.
step "Check that Istio ${ISTIO_ACTIVE_VERSION} supports Kubernetes $(k8s_minor_of "${target}")"
# This is why Istio is upgraded BEFORE Kubernetes.
check_istio_k8s "${ISTIO_ACTIVE_VERSION}" "$(k8s_minor_of "${target}")"
# Last chance to stop.
confirm "Upgrade the control plane from ${current} to ${target}? The Kubernetes API will be away for about a minute." || fail "stopped by user"

# Announce the step.
step "Stop the control plane and back up its database and certificates"
# File name with the old version and a time stamp.
backup="${BACKUP_DIR}/control-plane-${current}-$(date +%Y%m%d-%H%M%S).tar"
# With the server stopped, the copy is consistent.
run docker compose stop server
# "docker cp ... -" writes the folder as a tar archive to standard output.
# The folder holds the cluster database (SQLite), the certificates and the token.
info "copying ${SERVER_CONTAINER}:/var/lib/rancher/k3s/server to ${backup}"
# The redirect stores the archive in .state/backups.
docker cp "${SERVER_CONTAINER}:/var/lib/rancher/k3s/server" - > "${backup}"
# Keep it private: it contains the keys of the cluster.
chmod 600 "${backup}"
# Remember the file and the version it belongs to, for the rollback script.
state_set K8S_CONTROL_PLANE_BACKUP "${backup}"
# The version to go back to.
state_set K8S_CONTROL_PLANE_ROLLBACK_VERSION "${current}"

# Announce the step.
step "Start the control plane with ${target}"
# Record the new version ...
state_set K8S_SERVER_VERSION "${target}"
# ... and write it into .env for docker-compose.yml.
write_compose_env
# Compose sees that the image of "server" changed and replaces only that
# container (--no-deps). The volume with the database is attached again;
# K3s upgrades what is stored in it when it starts.
run docker compose up -d --no-deps server
# Wait until the API answers again.
wait_api_ready 300
# Wait until the server node itself reports the new version.
wait_node_version server "${target}" 300
# The worker nodes reconnect on their own; all must be Ready again.
run kubectl wait --for=condition=Ready node --all --timeout=300s

# Announce the step.
step "Show the result"
# The server shows the new version, the workers still the old one. That is
# fine: nodes may be one minor version behind the control plane.
run kubectl get nodes --label-columns topology.kubernetes.io/zone
# K3s may have updated its own add-ons (DNS); wait until all is ready again.
wait_workloads_ready
# The services must still answer.
bash "${ROOT_DIR}/scripts/install/10-smoke-test.sh"
# Explain what is left to do.
info "Next: upgrade the worker nodes one by one with scripts/upgrade/21-k8s-upgrade-node.sh <node>"
