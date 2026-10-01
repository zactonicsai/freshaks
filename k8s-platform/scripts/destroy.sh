#!/usr/bin/env bash
# Remove the platform from one cluster and, for managed types, destroy the cluster.
#   scripts/destroy.sh <cluster> [--yes] [--force]
#     --yes    skip the interactive confirmation (Jenkins passes it after its own check)
#     --force  continue when the cluster API is unreachable or cleanup times out
# Order matters: workloads go first so load balancers and disks are released
# before the network and the cluster under them are deleted.
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

load_config "${1:-}"
shift || true
YES=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    --force) FORCE=1 ;;
    *) die "unknown option: $arg" ;;
  esac
done
need "$TF" kubectl

[[ "$(cfg '.cluster.protect // false')" != true ]] ||
  die "'$CLUSTER' is protected. Set cluster.protect: false in config/clusters/$CLUSTER.yaml through a reviewed commit first."
if ((!YES)); then
  read -r -p "Type the cluster name to destroy '$CLUSTER': " answer
  [[ "$answer" == "$CLUSTER" ]] || die "aborted"
fi

APPS="applications.argoproj.io"

# Wait until no cloud load balancer or dynamically provisioned volume is left.
wait_for_cloud_cleanup() {
  local deadline=$((SECONDS + 900)) lbs pvs
  while :; do
    lbs="$(kubectl get services --all-namespaces -o json | yq '[.items[] | select(.spec.type == "LoadBalancer")] | length')"
    pvs="$(kubectl get persistentvolumes -o json | yq '[.items[] | select(.spec.persistentVolumeReclaimPolicy == "Delete")] | length')"
    ((lbs + pvs > 0)) || return 0
    ((SECONDS < deadline)) || return 1
    echo "waiting for $lbs load balancer(s) and $pvs volume(s) to be released"
    sleep 15
  done
}

if managed; then tf_init cluster; fi

if get_kubeconfig 2>/dev/null && kubectl version --request-timeout=20s >/dev/null 2>&1; then
  log "1/3 Removing workloads through Argo CD"
  if kubectl get crd "$APPS" >/dev/null 2>&1; then
    # The root app's finalizer deletes every child Application, and each child
    # deletes its own resources, before the root object disappears.
    kubectl -n argocd delete "$APPS" root --ignore-not-found --wait=false
    kubectl -n argocd wait "$APPS" --all --for=delete --timeout=1200s ||
      { ((FORCE)) || die "applications are still deleting; fix the cause or rerun with --force"; }
  fi
  if managed; then
    # Volume claims created by StatefulSets are not owned by any Application,
    # and a load balancer may have been created by hand. Both outlive the cluster.
    kubectl delete persistentvolumeclaims --all --all-namespaces --wait=false
    kubectl get services --all-namespaces -o json |
      yq -r '.items[] | select(.spec.type == "LoadBalancer") | .metadata.namespace + " " + .metadata.name' |
      while read -r namespace name; do
        kubectl -n "$namespace" delete service "$name" --wait=false
      done
    wait_for_cloud_cleanup ||
      { ((FORCE)) || die "load balancers or volumes remain; remove them or rerun with --force"; }
  fi

  log "2/3 Destroying the GitOps bootstrap"
  tf_init bootstrap
  tf bootstrap destroy -input=false -auto-approve
  if ! managed; then
    # The cluster stays, so remove what Helm keeps on uninstall. Namespaces that
    # Argo CD created for apps are left in place: they may hold other workloads.
    kubectl delete namespace argocd --ignore-not-found --wait=false
    kubectl delete customresourcedefinitions --ignore-not-found --wait=false \
      applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io
  fi
else
  ((FORCE)) || die "the cluster API is not reachable. Rerun with --force to destroy the infrastructure anyway (cloud load balancers or disks may be left behind)."
  warn "cluster API unreachable: skipping in-cluster cleanup"
  # Everything in the bootstrap state lives inside the cluster, so it is only forgotten.
  tf_init bootstrap
  for resource in $(tf bootstrap state list 2>/dev/null || true); do
    tf bootstrap state rm "$resource" >/dev/null
  done
fi

log "3/3 Destroying the cluster"
if managed; then
  tf cluster destroy -input=false -auto-approve
else
  echo "Type '$CLUSTER_TYPE' is not managed here. The cluster itself is left untouched."
fi

rm -rf "$BUILD_DIR"
if managed; then
  log "Done. '$CLUSTER' is destroyed."
else
  log "Done. The platform is removed from '$CLUSTER'."
fi
