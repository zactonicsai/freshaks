#!/usr/bin/env bash
# =============================================================================
# 02-start-cluster.sh — start the Kubernetes cluster as Docker containers:
# one control-plane node, three worker nodes, two image registries, the edge
# load balancer and the tools container (see docker-compose.yml).
# Safe to run again: it changes only what differs.
# Usage: ./scripts/install/02-start-cluster.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Announce the step.
step "Remember the settings of this install (first run only)"
# Ports, network and host names are fixed from now on. Later runs read them
# from .state, even when the environment says something else.
for setting in HTTPS_PORT API_PORT REGISTRY_PORT SUBNET_PREFIX BASE_DOMAIN; do
  # Store the value unless one is stored already.
  state_pin "${setting}"
done
# Show what is used.
info "https port ${HTTPS_PORT}, API port ${API_PORT}, registry port ${REGISTRY_PORT}, network ${SUBNET_PREFIX}.0/24, domain ${BASE_DOMAIN}"

# Announce the step.
step "Decide token and node versions (first run only)"
# The shared secret that lets worker nodes join the control plane.
secret_ensure K3S_TOKEN
# On the first run every node starts with the OLD Kubernetes version. Later
# runs keep whatever the upgrade scripts have recorded.
if [[ -z "${K8S_SERVER_VERSION:-}" ]]; then state_set K8S_SERVER_VERSION "${K8S_VERSION_OLD}"; fi
# The same for every worker node.
for node in "${AGENT_LIST[@]}"; do
  # Name of the state key, e.g. K8S_AGENT_1_VERSION.
  key="$(node_version_key "${node}")"
  # Set it only when it is still empty.
  if [[ -z "${!key:-}" ]]; then state_set "${key}" "${K8S_VERSION_OLD}"; fi
done
# Write .env for docker-compose.yml.
write_compose_env

# Announce the step.
step "Build the tools image (kubectl ${KUBECTL_VERSION}, helm ${HELM_VERSION})"
# Builds docker/tools/Dockerfile; quick when nothing changed.
run docker compose build tools

# Announce the step.
step "Start the containers"
# -d = in the background. Containers that already run are left alone.
run docker compose up -d
# Show them.
run docker compose ps

# Announce the step.
step "Wait for the Kubernetes API (up to 3 minutes)"
# Asks the server container until its API answers "ok".
wait_api_ready 180

# Announce the step.
step "Write the kubeconfig files"
# K3s writes an admin kubeconfig inside the server container. Its address is
# https://127.0.0.1:6443. Two copies are made, both readable only by you
# (umask 077): one for the tools container, where the server is called "server" ...
(umask 077 && docker exec "${SERVER_CONTAINER}" cat /etc/rancher/k3s/k3s.yaml | sed "s|https://127.0.0.1:6443|https://server:6443|" > "${KUBECONFIG_TOOLS}")
# ... and one for a kubectl on your own machine, through the published port.
(umask 077 && docker exec "${SERVER_CONTAINER}" cat /etc/rancher/k3s/k3s.yaml | sed "s|https://127.0.0.1:6443|https://127.0.0.1:${API_PORT}|" > "${KUBECONFIG_HOST}")
# From here on kubectl and helm work (they run in the tools container).
run kubectl version

# Announce the step.
step "Wait until all four nodes have joined and are Ready (up to 5 minutes)"
# Number of nodes we expect: the workers plus the control plane.
expected=$(( ${#AGENT_LIST[@]} + 1 ))
# Seconds waited so far.
waited=0
# Count the lines of "kubectl get nodes" until all nodes are listed.
until (( $(kubectl get nodes --no-headers 2>/dev/null | wc -l) >= expected )); do
  # Give up after 5 minutes.
  if (( waited >= 300 )); then run kubectl get nodes || true; fail "Not all nodes joined. Check: docker compose ps, docker logs ${PROJECT_NAME}-agent-1"; fi
  # Wait a little before the next try.
  sleep 5
  # Count the waiting time.
  waited=$((waited + 5))
done
# Now wait until each of them reports Ready.
run kubectl wait --for=condition=Ready node --all --timeout=300s
# Show nodes, versions and pretend zones.
run kubectl get nodes --output wide --label-columns topology.kubernetes.io/zone

# Announce the step.
step "Raise two kernel limits if they are low (Linux hosts)"
# Every kubelet and every Istio proxy watches files ("inotify"). The limits
# are shared by all containers of one machine; common defaults (128 watchers)
# are too low for four nodes and lead to "too many open files" errors.
instances="$(docker exec "${SERVER_CONTAINER}" sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
# Raise the number of watcher groups to 1024 when it is lower. A privileged
# container may change this setting of the shared kernel; it lasts until reboot.
if (( instances < 1024 )); then run docker exec "${SERVER_CONTAINER}" sysctl -w fs.inotify.max_user_instances=1024 || warn "could not raise fs.inotify.max_user_instances (now ${instances})"; fi
# The same for the number of watched files.
watches="$(docker exec "${SERVER_CONTAINER}" sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
# Raise it to 524288 when it is lower.
if (( watches < 524288 )); then run docker exec "${SERVER_CONTAINER}" sysctl -w fs.inotify.max_user_watches=524288 || warn "could not raise fs.inotify.max_user_watches (now ${watches})"; fi

# Announce the step.
step "Run two DNS pods instead of one"
# K3s starts a single CoreDNS pod. Every pod asks it for names, so while it
# moves during a node upgrade the whole cluster cannot resolve names. Two pods
# on two nodes close that gap. K3s creates the Deployment a few seconds after
# the API is up, so wait for it first (up to 2 minutes).
waited=0
# Ask for the Deployment until it exists.
until kubectl --namespace kube-system get deployment coredns >/dev/null 2>&1; do
  # Give up after 2 minutes.
  if (( waited >= 120 )); then fail "K3s did not create the CoreDNS Deployment."; fi
  # Wait a little before the next try.
  sleep 5
  # Count the waiting time.
  waited=$((waited + 5))
done
# Ask for two pods.
run kubectl --namespace kube-system scale deployment coredns --replicas=2
# Wait until both are ready.
wait_rollout kube-system deployment/coredns 5m
# Final message.
ok "the cluster is running. For your own kubectl: export KUBECONFIG=${ROOT_DIR}/${KUBECONFIG_HOST}"
