#!/usr/bin/env bash
# =============================================================================
#  destroy/01-destroy-kubernetes-workloads.sh — empty the cluster (helm + kubectl)
# =============================================================================
#  Deletes everything in the non-system namespaces IN AN ORDER THAT LETS AZURE
#  CLEAN UP AFTER ITSELF. Deleting the cluster with workloads still inside it
#  works, but leaves orphans behind (public IPs still in the node RG, disks
#  from Retain PVs, DNS records). The order here avoids that:
#
#    1. helm uninstall every release            -> charts remove their own objects
#    2. delete Services of type LoadBalancer    -> cloud-controller removes Azure LB rules + public IPs
#    3. delete Ingresses                        -> ingress controllers / AGIC release listeners
#    4. delete PersistentVolumeClaims           -> CSI driver deletes disks whose PV says reclaim=Delete
#    5. delete the namespaces                   -> everything else; `default` is emptied, not deleted
#    6. wait for PVs to be released; report Retain volumes (their disks survive)
#
#  Options (env vars)
#    HELM_TIMEOUT=10m                  per-release uninstall wait
#    NS_DELETE_TIMEOUT=600             seconds to wait for a namespace to disappear
#    FORCE_NAMESPACE_FINALIZERS=false  clear finalizers of namespaces stuck in Terminating
#    DELETE_RETAINED_PVS=false         also delete PersistentVolumes with reclaimPolicy=Retain
#                                      (the Azure disk behind them is NOT deleted here — see 03-destroy-disks.sh)
#
#  helm commands used:
#     helm list -A -o json                                every release with its namespace
#     helm uninstall <rel> -n <ns> --wait --timeout <t>   delete the release and wait for its objects to go
#  kubectl commands used:
#     kubectl get svc -A -o json                          find LoadBalancer services
#     kubectl delete svc/ingress/pvc <name> -n <ns>       ordered deletions, --wait so Azure clean-up has happened
#     kubectl delete namespace <ns> --wait=false           start namespace deletion, then poll
#     kubectl get ns <ns>                                  poll until NotFound
#     kubectl replace --raw /api/v1/namespaces/<ns>/finalize   force-finalise a stuck namespace (opt-in)
#     kubectl get pv -o json                               check which volumes were released / retained
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
require_tools kubectl helm jq
aks_credentials

HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
NS_DELETE_TIMEOUT="${NS_DELETE_TIMEOUT:-600}"
FORCE_NAMESPACE_FINALIZERS="${FORCE_NAMESPACE_FINALIZERS:-false}"
DELETE_RETAINED_PVS="${DELETE_RETAINED_PVS:-false}"

hr
warn "This deletes ALL workloads in these namespaces of cluster $CLUSTER_NAME:"
target_namespaces | sed 's/^/    /'
confirm "$CLUSTER_NAME"

# ns_in_scope <ns> -> 0 when the namespace is one we are allowed to touch
ns_in_scope() {
  if is_system_ns "$1"; then return 1; fi
  if [[ -n "$K8S_NAMESPACES" ]]; then
    # shellcheck disable=SC2086
    in_list "$1" $K8S_NAMESPACES
    return $?
  fi
  return 0
}

# --- 1. Helm releases -------------------------------------------------------------
hr; log "Step 1/6: helm uninstall"
releases="$(helm list -A -o json)"
while IFS='|' read -r ns name; do
  [[ -z "$name" ]] && continue
  if ! ns_in_scope "$ns"; then log "  skip $ns/$name (out of scope)"; continue; fi
  log "  helm uninstall $ns/$name"
  run helm uninstall "$name" -n "$ns" --wait --timeout "$HELM_TIMEOUT" || warn "helm uninstall $ns/$name failed — continuing"
done < <(jq -r '.[] | [.namespace, .name] | join("|")' <<<"$releases")

# --- 2. LoadBalancer services (release Azure load balancer rules + public IPs) ----
hr; log "Step 2/6: delete LoadBalancer services"
svcs="$(kubectl get svc -A -o json)"
while IFS='|' read -r ns name; do
  [[ -z "$name" ]] && continue
  if ! ns_in_scope "$ns"; then continue; fi
  log "  delete svc $ns/$name"
  run kubectl delete svc "$name" -n "$ns" --wait=true --timeout=5m || warn "could not delete svc $ns/$name"
done < <(jq -r '.items[] | select(.spec.type == "LoadBalancer") | [.metadata.namespace, .metadata.name] | join("|")' <<<"$svcs")

# --- 3. Ingresses -----------------------------------------------------------------
hr; log "Step 3/6: delete ingresses"
while IFS= read -r ns; do
  [[ -z "$ns" ]] && continue
  run kubectl delete ingress --all -n "$ns" --wait=true --timeout=5m || warn "ingress deletion in $ns failed"
done < <(target_namespaces)

# --- 4. PersistentVolumeClaims (lets the CSI driver delete reclaim=Delete disks) ---
hr; log "Step 4/6: delete persistent volume claims"
while IFS= read -r ns; do
  [[ -z "$ns" ]] && continue
  run kubectl delete pvc --all -n "$ns" --wait=true --timeout=10m || warn "pvc deletion in $ns failed"
done < <(target_namespaces)

# --- 5. Namespaces -----------------------------------------------------------------
# wait_ns_gone <ns> <seconds> -> 0 when the namespace no longer exists
wait_ns_gone() {
  local ns="$1" timeout="$2" waited=0
  if [[ "$DRY_RUN" == "true" ]]; then return 0; fi
  while kubectl get ns "$ns" >/dev/null 2>&1; do
    if [[ "$waited" -ge "$timeout" ]]; then return 1; fi
    sleep 5
    waited=$((waited + 5))
  done
  return 0
}

# empty_default_namespace — `default` cannot be deleted, so delete its contents
empty_default_namespace() {
  local kind name
  for kind in cronjob job hpa deploy sts ds svc ingress pvc cm secret; do
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      run kubectl delete "$kind" "$name" -n default --wait=true --timeout=5m || warn "could not delete $kind default/$name"
    done < <(kubectl get "$kind" -n default -o json 2>/dev/null | jq -r '
        .items[]
        | select(.metadata.name != "kubernetes" and .metadata.name != "kube-root-ca.crt")
        | select((.type // "") != "kubernetes.io/service-account-token")
        | select(((.metadata.ownerReferences // []) | length) == 0)
        | .metadata.name')
  done
}

hr; log "Step 5/6: delete namespaces"
while IFS= read -r ns; do
  [[ -z "$ns" ]] && continue
  if [[ "$ns" == "default" ]]; then
    log "  emptying namespace default (it cannot be deleted)"
    empty_default_namespace
    continue
  fi
  log "  delete namespace $ns"
  run kubectl delete namespace "$ns" --wait=false || { warn "delete namespace $ns failed"; continue; }
  if wait_ns_gone "$ns" "$NS_DELETE_TIMEOUT"; then
    ok "namespace $ns gone"
    continue
  fi
  if [[ "$FORCE_NAMESPACE_FINALIZERS" == "true" ]]; then
    warn "namespace $ns stuck in Terminating — clearing finalizers"
    kubectl get ns "$ns" -o json | jq '.spec.finalizers = []' \
      | run kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - >/dev/null \
      || warn "finalize call failed for $ns"
    wait_ns_gone "$ns" 120 || warn "namespace $ns is still present"
  else
    warn "namespace $ns still Terminating after ${NS_DELETE_TIMEOUT}s. Re-run with FORCE_NAMESPACE_FINALIZERS=true, or inspect: kubectl get ns $ns -o yaml"
  fi
done < <(target_namespaces)

# --- 6. Persistent volumes ---------------------------------------------------------
hr; log "Step 6/6: persistent volumes"
if [[ "$DRY_RUN" != "true" ]]; then
  # Give the CSI driver up to 5 minutes to delete reclaim=Delete volumes.
  waited=0
  while :; do
    pending="$(kubectl get pv -o json | jq '[.items[] | select(.spec.persistentVolumeReclaimPolicy == "Delete" and .status.phase != "Bound")] | length')"
    if [[ "$pending" -eq 0 || "$waited" -ge 300 ]]; then break; fi
    log "  waiting for $pending released volume(s) to be deleted by the CSI driver ..."
    sleep 10; waited=$((waited + 10))
  done
fi
retained="$(kubectl get pv -o json | jq -r '.items[] | select(.spec.persistentVolumeReclaimPolicy == "Retain" and .status.phase != "Bound") | .metadata.name + " -> " + (.spec.csi.volumeHandle // .spec.azureDisk.diskURI // "?")')"
if [[ -n "$retained" ]]; then
  warn "PersistentVolumes with reclaimPolicy=Retain (their Azure disks/shares survive; see 03-destroy-disks.sh):"
  printf '    %s\n' "$retained"
  if [[ "$DELETE_RETAINED_PVS" == "true" ]]; then
    while IFS= read -r line; do
      pv="${line%% ->*}"
      [[ -z "$pv" ]] && continue
      run kubectl delete pv "$pv" --wait=false || warn "could not delete pv $pv"
    done <<<"$retained"
  fi
fi

hr
ok "Cluster workloads removed. Next: ./destroy/02-destroy-aks-cluster.sh"
