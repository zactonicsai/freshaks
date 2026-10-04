# shellcheck shell=bash
# shellcheck disable=SC2034
# =============================================================================
# config/env.sh — names, sizes and switches. Override any value by setting an
# environment variable before you run a script, e.g.  HTTPS_PORT=9443 ./scripts/...
# =============================================================================

# --- Docker ------------------------------------------------------------------
# Prefix of every container, volume and network that belongs to this example.
# Keep it in sync with "name:" in docker-compose.yml.
: "${PROJECT_NAME:=k8s-ha-demo}"
# First three numbers of the private network the containers share. Change it
# if "docker network create" reports an overlap with another network.
: "${SUBNET_PREFIX:=172.30.42}"
# Port on your machine for the web applications (https://app1.localhost:8443).
: "${HTTPS_PORT:=8443}"
# Port on your machine for the Kubernetes API (only needed for your own kubectl).
: "${API_PORT:=6443}"
# Port on your machine for the local image registry (docker push localhost:5001/...).
: "${REGISTRY_PORT:=5001}"
# The Kubernetes worker nodes: one container each, in three pretend "zones".
: "${AGENT_NODES:=agent-1 agent-2 agent-3}"
# Optional Docker Hub login for the image cache (raises the pull limit).
: "${DOCKERHUB_USERNAME:=}"
# Access token that belongs to DOCKERHUB_USERNAME.
: "${DOCKERHUB_TOKEN:=}"

# --- Host names --------------------------------------------------------------
# The applications are reached as app1.<BASE_DOMAIN>, app2.<BASE_DOMAIN> and
# keycloak.<BASE_DOMAIN>. Browsers resolve every *.localhost name to this machine.
: "${BASE_DOMAIN:=localhost}"

# --- Kubernetes node upgrades ------------------------------------------------
# How long "kubectl drain" may wait for pods to leave a node.
: "${DRAIN_TIMEOUT:=600s}"
# Pause after each upgraded node before the next one is touched.
: "${NODE_SOAK_SECONDS:=20}"

# --- Storage -----------------------------------------------------------------
# Size the NFS server pod reports for its backing "disk" (a Docker volume).
: "${NFS_DISK_SIZE:=20Gi}"
# Size of each PostgreSQL data volume.
: "${POSTGRES_DATA_SIZE:=2Gi}"
# Size of the shared volume for database dumps.
: "${BACKUP_VOLUME_SIZE:=2Gi}"
# Size of the shared volume for the notes of the two applications.
: "${SHARED_NOTES_SIZE:=1Gi}"

# --- Images ------------------------------------------------------------------
# Where the PostgreSQL image comes from.
: "${POSTGRES_IMAGE_REPOSITORY:=docker.io/library/postgres}"
# Where the Keycloak image comes from.
: "${KEYCLOAK_IMAGE_REPOSITORY:=quay.io/keycloak/keycloak}"
# Optional: registry path with mirrored Istio images (pilot, proxyv2).
# Empty = the registry named in the Istio charts.
: "${ISTIO_HUB:=}"

# --- Mesh --------------------------------------------------------------------
# Name of the Istio revision tag that namespaces and gateways refer to.
: "${ISTIO_TAG:=stable}"
# The one external host the apps may call; it is routed through the egress gateway.
: "${EGRESS_TEST_HOST:=api.ipify.org}"
# A host that is NOT allowed; the apps use it to show that the mesh blocks it.
: "${EGRESS_BLOCKED_HOST:=example.com}"

# --- Behaviour of the scripts --------------------------------------------------
# How long Helm waits for pods to become ready before it rolls a release back.
: "${HELM_TIMEOUT:=15m}"
# true = never ask "are you sure?" (for unattended runs).
: "${ASSUME_YES:=false}"
# Seconds between two requests of the availability probe.
: "${PROBE_INTERVAL:=1}"
