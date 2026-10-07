#!/usr/bin/env bash
# shellcheck disable=SC2034  # (these variables are used by the scripts that load this file)
# =============================================================================
# config.sh - the settings. create.sh, verify.sh and destroy.sh all read this
# file, so they always agree on the names.
#
# You can change a value here, or set it just for one run, like this:
#     LOCATION=eastus2 ./create.sh
# =============================================================================

# A resource group is a box in Azure that holds everything we make.
# Deleting the box deletes everything inside it.
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-keycloak-demo}"

# Which Azure data center to use. Pick one near you.
LOCATION="${LOCATION:-centralus}"

# The name of the Kubernetes cluster.
CLUSTER_NAME="${CLUSTER_NAME:-aks-keycloak-demo}"

# How many computers (nodes) are in the cluster, and how big each one is.
#
# CHEAPEST SETUP THAT STILL WORKS: 1 node with 4 CPUs.
# Why not smaller? The AKS Istio add-on always runs 2 copies of its brain
# (istiod) and 2 copies of the front door (gateway). Azure does not let you
# lower that. Together with Keycloak, Postgres and the app, that does not fit
# on a 2-CPU node.
#
# "auto" = create.sh looks at your quota and picks the cheapest 4-CPU size you
# are allowed to use (it tries the sizes in VM_SIZE_CHOICES, in order).
# Or name a size yourself, like NODE_VM_SIZE=Standard_D4s_v3.
NODE_COUNT="${NODE_COUNT:-1}"
NODE_VM_SIZE="${NODE_VM_SIZE:-auto}"

# Sizes to try for "auto", cheapest first. All have 4 CPUs and 16 GB memory.
# Each entry is  size:quota-family  (the family is how Azure counts your quota).
# The B sizes are "burstable": cheap, and fine for a demo that is mostly idle.
VM_SIZE_CHOICES="${VM_SIZE_CHOICES:-Standard_B4as_v2:standardBasv2Family Standard_B4ms:standardBSFamily Standard_D4as_v5:standardDASv5Family Standard_D4s_v3:standardDSv3Family Standard_D4s_v5:standardDSv5Family}"
VM_SIZE_CPUS=4

# Size of each node's own disk in GB. 32 is the cheapest disk tier and is
# plenty for this demo. (The default would be 128, which costs more.)
NODE_DISK_GB="${NODE_DISK_GB:-32}"

# THE ONE internet address that is allowed to reach Keycloak.
ALLOWED_IP="${ALLOWED_IP:-68.32.112.68}"

# true  = the Java app is ALSO locked to ALLOWED_IP (safest, the default).
# false = anyone on the internet can open the app's public page, but Keycloak
#         (the login page) still only answers ALLOWED_IP.
LOCK_APP_TO_ALLOWED_IP="${LOCK_APP_TO_ALLOWED_IP:-true}"

# Which Keycloak to run. Keycloak only fixes security bugs in its newest
# release, so check https://www.keycloak.org/downloads now and then.
KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.7.0}"

# ---- Fixed names. No need to change these. ----
# The Kubernetes YAML files use the namespace name "demo" directly.
NAMESPACE="demo"
INGRESS_NAMESPACE="aks-istio-ingress"
INGRESS_SERVICE="aks-istio-ingressgateway-external"

# Where the scripts keep their own files (both are in .gitignore).
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$PROJECT_DIR/.secrets.env"   # the passwords create.sh makes up
RENDER_DIR="$PROJECT_DIR/.rendered"        # filled-in copies of the templates

# Small helpers used by all scripts.
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }   # blue heading
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    WARNING: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m    ERROR: %s\033[0m\n' "$*" >&2; exit 1; }
