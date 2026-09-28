#!/usr/bin/env bash
# =============================================================================
#  99-destroy.sh — tear EVERYTHING down, in the reverse order it was built.
#  Every step ignores "not found" (so it is safe to run twice, or after a
#  half-finished setup) and keeps going if one step fails; failures are
#  listed at the end.
#
#     scripts/99-destroy.sh                 # asks you to type the resource group name
#     scripts/99-destroy.sh --yes           # no questions
#     scripts/99-destroy.sh --keep-cluster  # remove only what runs IN the cluster (steps 1-7)
#     scripts/99-destroy.sh --fast          # skip straight to "delete the resource group"
#     scripts/99-destroy.sh --wait          # wait for Azure to finish deleting the resource group
#
#  Order:  tests -> apps -> keycloak -> openldap -> postgres -> cert-manager
#          -> ingress-nginx -> node pool -> AKS cluster -> registry -> resource group -> local files
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

YES=false; KEEP_CLUSTER=false; FAST=false; WAIT=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=true ;;
    --keep-cluster) KEEP_CLUSTER=true ;;
    --fast) FAST=true ;;
    --wait) WAIT=true ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown option: $arg (try --help)" ;;
  esac
done
require_cmd az

FAILED=()

# try DESCRIPTION command args...
# Runs the command. Success -> "done". "Not found" -> "skipped". Anything else -> warn, remember, continue.
try() {
  local desc="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    log "$desc: done"
  elif grep -qiE 'not ?found|could ?not ?be ?found|does ?not ?exist|no ?such|no resources found|not loaded' <<<"$out"; then
    log "$desc: not found, skipping"
  else
    warn "$desc: failed (continuing)"
    printf '%s\n' "$out" | tail -n 3 | sed 's/^/        /' >&2
    FAILED+=("$desc")
  fi
}

# ---- confirmation ---------------------------------------------------------------
if ! $KEEP_CLUSTER; then
  echo "This will DELETE resource group '${RESOURCE_GROUP}' and everything in it (cluster, registry, disks, public IP)."
else
  echo "This will DELETE every namespace, Helm release and node pool the scripts created in cluster '${CLUSTER_NAME}'."
fi
if ! $YES; then
  read -r -p "Type the resource group name to confirm: " answer
  [[ "$answer" == "$RESOURCE_GROUP" ]] || die "Not confirmed. Nothing deleted."
fi

# ---- is there a cluster we can talk to? -------------------------------------------
cluster_exists() { az aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; }
kube_reachable() { command -v kubectl >/dev/null && kubectl cluster-info --request-timeout=15s >/dev/null 2>&1; }

if ! $FAST; then
  if cluster_exists; then
    if ! kube_reachable; then
      step "0/12 Fetching kubectl credentials (needed to clean inside the cluster)"
      try "aks get-credentials" az aks get-credentials --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --overwrite-existing --output none
    fi
  else
    warn "Cluster '${CLUSTER_NAME}' not found — skipping the in-cluster steps (1-7)."
  fi
fi

K="kubectl --request-timeout=60s"
ns_delete() { $K delete namespace "$1" --ignore-not-found --timeout=180s; }

if ! $FAST && kube_reachable; then
  step "1/12 Inspectors (namespace ${NS_TESTS})"
  try "delete test jobs"       $K -n "$NS_TESTS" delete job --all --ignore-not-found --timeout=60s
  try "delete namespace ${NS_TESTS}" ns_delete "$NS_TESTS"

  step "2/12 Apps: java store + python deli (namespace ${NS_APPS})"
  try "delete ingresses in ${NS_APPS}"   $K -n "$NS_APPS" delete ingress --all --ignore-not-found --timeout=60s
  try "delete deployments in ${NS_APPS}" $K -n "$NS_APPS" delete deployment --all --ignore-not-found --timeout=120s
  try "delete namespace ${NS_APPS}" ns_delete "$NS_APPS"

  step "3/12 Keycloak (Helm release in ${NS_IDENTITY})"
  if command -v helm >/dev/null; then
    try "helm uninstall keycloak" helm uninstall keycloak --namespace "$NS_IDENTITY" --wait --timeout 5m
  else
    warn "helm not installed — the keycloak release objects will go away with the namespace"
  fi

  step "4/12 OpenLDAP (namespace ${NS_IDENTITY})"
  try "delete openldap deployment" $K -n "$NS_IDENTITY" delete deployment openldap --ignore-not-found --timeout=60s
  try "delete namespace ${NS_IDENTITY}" ns_delete "$NS_IDENTITY"

  step "5/12 Postgres + its disk (namespace ${NS_DATA})"
  try "delete postgres statefulset" $K -n "$NS_DATA" delete statefulset postgres --ignore-not-found --timeout=120s
  try "delete postgres volume claims" $K -n "$NS_DATA" delete pvc --all --ignore-not-found --timeout=120s
  try "delete namespace ${NS_DATA}" ns_delete "$NS_DATA"

  step "6/12 cert-manager (only present when ENABLE_TLS=true)"
  try "delete ClusterIssuer letsencrypt-prod" $K delete clusterissuer letsencrypt-prod --ignore-not-found --timeout=60s
  if command -v helm >/dev/null; then
    try "helm uninstall cert-manager" helm uninstall cert-manager --namespace cert-manager --wait --timeout 5m
  fi
  try "delete cert-manager CRDs" $K delete crd -l app.kubernetes.io/name=cert-manager --ignore-not-found --timeout=60s
  try "delete namespace cert-manager" ns_delete cert-manager

  step "7/12 ingress-nginx (releases the public IP)"
  if command -v helm >/dev/null; then
    try "helm uninstall ingress-nginx" helm uninstall ingress-nginx --namespace ingress-nginx --wait --timeout 5m
  fi
  try "delete namespace ingress-nginx" ns_delete ingress-nginx
fi

if $KEEP_CLUSTER; then
  step "Node pool 'apps' (created by 02)"
  try "delete node pool apps" az aks nodepool delete --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --name apps --output none
  rm -f "$ROOT_DIR/helm/keycloak/values-generated.yaml"
  log "Cluster '${CLUSTER_NAME}' and resource group '${RESOURCE_GROUP}' were kept (--keep-cluster)."
  log "Re-run scripts/02-setup-nodes.sh onward to rebuild."
  exit 0
fi

if ! $FAST; then
  step "8/12 Node pool 'apps'"
  if cluster_exists; then
    try "delete node pool apps" az aks nodepool delete --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --name apps --output none
  else
    log "cluster not found, skipping"
  fi

  step "9/12 AKS cluster '${CLUSTER_NAME}' (a few minutes)"
  try "delete AKS cluster" az aks delete --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --yes --output none

  step "10/12 Container registry"
  ACR_NAME="${ACR_NAME:-$(az acr list --resource-group "$RESOURCE_GROUP" --query '[0].name' -o tsv 2>/dev/null || true)}"
  if [[ -n "${ACR_NAME:-}" ]]; then
    try "delete registry ${ACR_NAME}" az acr delete --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --yes --output none
  else
    log "no registry found, skipping"
  fi
fi

step "11/12 Resource group '${RESOURCE_GROUP}' (everything left inside it)"
if $WAIT; then
  try "delete resource group" az group delete --name "$RESOURCE_GROUP" --yes --output none
else
  try "delete resource group (in the background)" az group delete --name "$RESOURCE_GROUP" --yes --no-wait --output none
fi

step "12/12 Local leftovers"
rm -f "$GENERATED_ENV" "$ROOT_DIR/helm/keycloak/values-generated.yaml"
if command -v kubectl >/dev/null; then
  kubectl config delete-context "$CLUSTER_NAME" >/dev/null 2>&1 || true
  kubectl config delete-cluster "$CLUSTER_NAME" >/dev/null 2>&1 || true
  kubectl config unset "users.clusterUser_${RESOURCE_GROUP}_${CLUSTER_NAME}" >/dev/null 2>&1 || true
fi
log "removed scripts/.generated.env, helm/keycloak/values-generated.yaml and the kubectl context"

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
  warn "${#FAILED[@]} step(s) failed — run the script again, or delete by hand:"
  printf '   - %s\n' "${FAILED[@]}" >&2
  warn "Check what is left with:  az group show -n ${RESOURCE_GROUP}   /   az resource list -g ${RESOURCE_GROUP} -o table"
  exit 1
fi
if $WAIT; then
  log "All gone. Verify with:  az group show -n ${RESOURCE_GROUP}   (should say ResourceGroupNotFound)"
else
  log "All deletions issued. Azure finishes the resource group in the background; verify with:  az group show -n ${RESOURCE_GROUP}"
fi
