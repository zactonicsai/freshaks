#!/usr/bin/env bash
# Create or update one cluster and bootstrap GitOps on it.
#   scripts/deploy.sh <cluster> [plan|apply]        default: apply
# Workloads are not deployed from here. After the bootstrap, Argo CD applies
# whatever config/global.yaml and the cluster file say in Git.
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

load_config "${1:-}"
MODE="${2:-apply}"
[[ "$MODE" == plan || "$MODE" == apply ]] || die "mode must be 'plan' or 'apply'"
need "$TF" kubectl
[[ "$(cfg '.gitops.repoURL')" != *your-org* ]] ||
  die "set gitops.repoURL in config/global.yaml to your own repository first; Argo CD deploys from there"

# fingerprint <stack>: changes whenever the config or the Terraform code changes.
fingerprint() { cat "$CONFIG_FILE" "$(stack_dir "$1")"/*.tf | cksum; }

# run_stack <stack>: plan only, or apply. A saved plan is applied only when the
# configuration it was made from is unchanged; otherwise Terraform plans again.
run_stack() {
  local stack="$1" plan="$BUILD_DIR/$1.tfplan"
  tf_init "$stack"
  if [[ "$MODE" == plan ]]; then
    tf "$stack" plan -input=false -out="$plan"
    fingerprint "$stack" >"$plan.sum"
    return
  fi
  if [[ -f "$plan" && "$(cat "$plan.sum" 2>/dev/null)" == "$(fingerprint "$stack")" ]]; then
    tf "$stack" apply -input=false "$plan"
  else
    tf "$stack" apply -input=false -auto-approve
  fi
  rm -f "$plan" "$plan.sum"
}

# preflight: the conformance gate. Same check for every provider.
preflight() {
  local have want
  kubectl version -o json >"$BUILD_DIR/version.json" 2>/dev/null ||
    die "the cluster API is not reachable with $KUBECONFIG"
  have="$(yq -r '.serverVersion.major + "." + (.serverVersion.minor | sub("[^0-9]+$", ""))' "$BUILD_DIR/version.json")"
  want="$(cfg '.platform.minKubernetesVersion')"
  [[ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n 1)" == "$want" ]] ||
    die "cluster runs Kubernetes $have; this platform needs $want or newer (platform.minKubernetesVersion)"
  kubectl auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 ||
    die "the bootstrap needs cluster-admin on $CLUSTER"
  kubectl wait --for=condition=Ready nodes --all --timeout=600s >/dev/null ||
    die "the nodes of $CLUSTER did not become Ready"
  echo "Kubernetes $have (minimum $want), cluster-admin confirmed, nodes ready"
}

wait_for_apps() {
  local apps="applications.argoproj.io" timeout="${SYNC_TIMEOUT:-900}s"
  if kubectl -n argocd wait "$apps/root" --for=jsonpath='{.status.sync.status}'=Synced --timeout="$timeout" &&
    kubectl -n argocd wait "$apps" --all --for=jsonpath='{.status.health.status}'=Healthy --timeout="$timeout"; then
    kubectl -n argocd get "$apps"
  else
    kubectl -n argocd get "$apps" || true
    die "Argo CD did not reach Synced and Healthy within $timeout"
  fi
}

log "1/4 Cluster '$CLUSTER' (type: $CLUSTER_TYPE)"
if managed; then
  run_stack cluster
else
  echo "Type '$CLUSTER_TYPE' uses a cluster that already exists. Nothing to create."
fi

log "2/4 Kubeconfig and preflight"
if [[ "$MODE" == plan ]]; then
  if ! get_kubeconfig 2>/dev/null; then
    warn "cluster is not reachable yet; the GitOps bootstrap is planned on the first apply"
    exit 0
  fi
else
  get_kubeconfig || die "could not get a kubeconfig for '$CLUSTER'"
fi
preflight

log "3/4 GitOps bootstrap: Argo CD and the root application"
run_stack bootstrap
[[ "$MODE" == apply ]] || exit 0

log "4/4 Waiting for Argo CD to sync what Git declares"
wait_for_apps
log "Done. '$CLUSTER' now follows Git: change config/, commit, and Argo CD applies it."
