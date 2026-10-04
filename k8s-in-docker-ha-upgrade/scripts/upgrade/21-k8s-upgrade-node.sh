#!/usr/bin/env bash
# =============================================================================
# 21-k8s-upgrade-node.sh — upgrade ONE worker node to the version of the
# control plane, the way it is done on real machines:
#   1. cordon   no new pods on this node
#   2. drain    ask the pods to leave; PodDisruptionBudgets make sure that
#               at least one pod of every service keeps running elsewhere
#   3. take the node out of the load balancer
#   4. replace the node's container with the new K3s image
#   5. wait until the node is Ready with the new version
#   6. put it back into the load balancer, uncordon it
#   7. wait until every workload is complete again before the next node
# Usage: ./scripts/upgrade/21-k8s-upgrade-node.sh NODE [VERSION]
#        NODE = agent-1, agent-2 or agent-3; default VERSION = control plane version
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the cluster is not running.
require_cluster
# The control plane version must be known.
require_state K8S_SERVER_VERSION "scripts/install/02-start-cluster.sh"
# The node: first argument.
node="${1:?usage: 21-k8s-upgrade-node.sh NODE [VERSION]   (NODE = one of: ${AGENT_NODES})}"
# It must be one of the worker nodes (the spaces make sure "agent-1" does not match "agent-10").
[[ " ${AGENT_NODES} " == *" ${node} "* ]] || fail "'${node}' is not a worker node. Choose one of: ${AGENT_NODES}"
# Target: second argument, or the version of the control plane.
target="${2:-${K8S_SERVER_VERSION}}"
# Name of the state key of this node, e.g. K8S_AGENT_1_VERSION.
key="$(node_version_key "${node}")"
# Version the node runs now.
current="${!key}"
# Already there: done.
if [[ "${current}" == "${target}" ]]; then ok "node ${node} already runs ${target}"; exit 0; fi

# Announce the step.
step "Checks before touching ${node}"
# A node must never be newer than the control plane.
if [[ "$(printf '%s\n%s\n' "${target}" "${K8S_SERVER_VERSION}" | sort -V | tail -n 1)" != "${K8S_SERVER_VERSION}" ]]; then fail "${target} is newer than the control plane (${K8S_SERVER_VERSION}). Upgrade the control plane first: scripts/upgrade/20-k8s-upgrade-control-plane.sh"; fi
# A budget that allows 0 disruptions would make the drain wait forever.
blocking="$(kubectl get poddisruptionbudgets --all-namespaces --output jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.status.disruptionsAllowed}{"\n"}{end}' | awk '$2 == 0 { print $1 }')"
# Stop before anything is changed.
if [[ -n "${blocking}" ]]; then fail "These PodDisruptionBudgets allow 0 disruptions and would block the drain: $(printf '%s' "${blocking}" | tr '\n' ' ') - wait until all pods are ready (scripts/tools/show-status.sh)"; fi
# Report success.
ok "no budget blocks the drain"
# Show which pods run on the node right now.
run kubectl get pods --all-namespaces --field-selector "spec.nodeName=${node}" --output wide

# Announce the step.
step "Cordon ${node}: no new pods are scheduled here"
# The node shows "SchedulingDisabled" from now on.
run kubectl cordon "${node}"

# Announce the step.
step "Drain ${node}: move its pods to the other nodes"
# --ignore-daemonsets: pods that belong to every node stay.
# --delete-emptydir-data: pods with scratch folders may be evicted too.
# The drain asks politely ("eviction"): a pod is only removed when its
# PodDisruptionBudget allows it, otherwise the drain waits and retries.
run kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --timeout="${DRAIN_TIMEOUT}"

# Announce the step.
step "Take ${node} out of the edge load balancer"
# New connections go to the other nodes from now on.
edge_node_state "${node}" drain
# Give requests that are in flight a moment to finish.
sleep 5

# Announce the step.
step "Replace the container of ${node}: ${current} -> ${target}"
# Record the new version ...
state_set "${key}" "${target}"
# ... and write it into .env for docker-compose.yml.
write_compose_env
# Compose replaces only this container (--no-deps). Its volumes (downloaded
# images, node identity) are attached again, so it comes back as the same node.
run docker compose up -d --no-deps "${node}"
# Wait until the node reports the new version and is Ready.
wait_node_version "${node}" "${target}" 300

# Announce the step.
step "Put ${node} back into service"
# The load balancer may send connections to it again.
edge_node_state "${node}" ready
# Pods may be scheduled here again.
run kubectl uncordon "${node}"

# Announce the step.
step "Wait until every workload is complete again"
# Pods that moved away must be ready before the next node is touched.
wait_workloads_ready
# A short pause to notice problems before the next node.
sleep "${NODE_SOAK_SECONDS}"
# One quick request per application through the load balancer.
expect_code "app1 still answers" 200 "https://app1.${PUBLIC_DOMAIN}/api/info"
# Same for application 2.
expect_code "app2 still answers" 200 "https://app2.${PUBLIC_DOMAIN}/api/info"
# Show the nodes with their versions.
run kubectl get nodes --label-columns topology.kubernetes.io/zone
