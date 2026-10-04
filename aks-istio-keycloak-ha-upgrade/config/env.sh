# shellcheck shell=bash
# shellcheck disable=SC2034
# =============================================================================
# config/env.sh — everything you may want to change before the first run.
# Override any value without editing this file, for example:
#     LOCATION=westeurope PREFIX=myteam ./scripts/install/install-all.sh
# =============================================================================

# --- Naming ------------------------------------------------------------------
# Short lowercase word that is put into every Azure resource name.
: "${PREFIX:=hademo}"
# Azure region. It must offer three availability zones.
: "${LOCATION:=eastus2}"
# Resource group that holds everything this example creates.
: "${RESOURCE_GROUP:=rg-${PREFIX}}"
# Name of the AKS cluster.
: "${AKS_NAME:=aks-${PREFIX}}"
# Name of the static public IP address used by the Istio ingress gateway.
: "${PUBLIC_IP_NAME:=pip-${PREFIX}-ingress}"
# Container registry name. Leave empty and a unique name is generated for you.
: "${ACR_NAME:=}"
# Azure subscription to use. Leave empty to use the one "az" currently points at.
: "${SUBSCRIPTION_ID:=}"

# --- Cluster size (drives cost and vCPU quota) ---------------------------------
# Name of the system node pool (runs CoreDNS, metrics-server and friends).
: "${SYSTEM_POOL_NAME:=system}"
# Three system nodes = one per availability zone.
: "${SYSTEM_NODE_COUNT:=3}"
# 2 vCPU / 8 GiB each.
: "${SYSTEM_NODE_SIZE:=Standard_D2s_v5}"
# Name of the user node pool (runs Istio, NFS, PostgreSQL, Keycloak and the apps).
: "${USER_POOL_NAME:=apps}"
# Three user nodes = one per availability zone.
: "${USER_NODE_COUNT:=3}"
# 4 vCPU / 16 GiB each.
: "${USER_NODE_SIZE:=Standard_D4s_v5}"
# Availability zones to spread the nodes over.
: "${ZONES:=1 2 3}"
# "standard" buys the financially backed uptime SLA for the control plane.
: "${AKS_TIER:=standard}"
# How many extra nodes AKS may add while it upgrades a pool (one third here).
: "${MAX_SURGE:=33%}"
# Minutes AKS waits for the pods of one node to leave before it gives up on that node.
: "${DRAIN_TIMEOUT_MINUTES:=30}"
# Minutes AKS waits after each upgraded node before it touches the next one
# (time for you, or your monitoring, to notice a problem).
: "${NODE_SOAK_MINUTES:=1}"
# How upgrade-all replaces the nodes of the user pool:
# "surge"     = upgrade the pool in place, node by node (az aks nodepool upgrade).
# "bluegreen" = create a second pool with the new version, move the pods, then
#               delete the old pool (needs more quota, gives an instant way back).
: "${NODEPOOL_STRATEGY:=surge}"
# Private address range handed out to pods (Azure CNI Overlay).
: "${POD_CIDR:=10.244.0.0/16}"
# Registry tier. "Premium" adds zone redundancy and geo-replication (use it in production).
: "${ACR_SKU:=Standard}"

# --- Storage -------------------------------------------------------------------
# "nfs-pod"        = an NFS server pod backed by an Azure managed disk (default).
# "azurefiles-nfs" = Azure Files NFS shares, managed by Azure (no NFS pod).
: "${STORAGE_BACKEND:=nfs-pod}"
# Disk type behind the NFS pod. Premium_ZRS disks can attach in any zone, so the
# NFS pod can restart on any node. Use Premium_LRS if your region has no ZRS disks.
: "${NFS_BACKING_DISK_SKU:=Premium_ZRS}"
# Size of the disk behind the NFS pod.
: "${NFS_DISK_SIZE:=64Gi}"
# Size of the PostgreSQL data volume.
: "${POSTGRES_DATA_SIZE:=8Gi}"
# Size of the shared backup volume (mounted by the old and the new PostgreSQL).
: "${BACKUP_VOLUME_SIZE:=10Gi}"
# Size of the volume shared by all four application pods.
: "${SHARED_NOTES_SIZE:=1Gi}"

# --- Images --------------------------------------------------------------------
# "false" builds with local Docker; "true" builds inside Azure (no Docker needed).
: "${USE_ACR_BUILD:=false}"
# Where the PostgreSQL image comes from (point it at your ACR after mirroring).
: "${POSTGRES_IMAGE_REPOSITORY:=docker.io/library/postgres}"
# Where the Keycloak image comes from.
: "${KEYCLOAK_IMAGE_REPOSITORY:=quay.io/keycloak/keycloak}"
# Optional: registry path that holds mirrored Istio images (pilot, proxyv2).
# Leave empty to pull them from the public registry named in the Istio charts.
: "${ISTIO_HUB:=}"

# --- Mesh ----------------------------------------------------------------------
# The one external host the apps may call; it is routed through the egress gateway.
: "${EGRESS_TEST_HOST:=api.ipify.org}"
# A host that is NOT allowed, used to prove that everything else is blocked.
: "${EGRESS_BLOCKED_HOST:=example.com}"
# Name of the revision tag that namespaces point at ("stable" moves between versions).
: "${ISTIO_TAG:=stable}"

# --- Behaviour -----------------------------------------------------------------
# How long Helm waits for pods to become ready before it gives up and rolls back.
: "${HELM_TIMEOUT:=15m}"
# Set to "true" to skip the "are you sure?" questions (used by CI).
: "${ASSUME_YES:=false}"
# Seconds between two rounds of the availability probe.
: "${PROBE_INTERVAL:=1}"
