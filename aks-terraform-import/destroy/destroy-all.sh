#!/usr/bin/env bash
# =============================================================================
#  destroy/destroy-all.sh — full teardown with az cli + kubectl + helm
# =============================================================================
#  Runs the CLI destroy scripts in order. This is the NON-Terraform path; the
#  Terraform equivalent is destroy/terraform-destroy.sh.
#
#    01-destroy-kubernetes-workloads.sh   helm uninstall, kubectl delete
#    02-destroy-aks-cluster.sh            az aks delete (removes the MC_ node RG)
#    then EITHER
#      06-destroy-resource-group.sh       az group delete   (default — fastest, Azure orders it)
#    OR, with DELETE_RESOURCE_GROUP=false (keep the empty group):
#      03-destroy-disks.sh
#      04-destroy-networking.sh
#      05-destroy-platform-services.sh
#
#  Options (env vars)
#    DELETE_RESOURCE_GROUP=true    delete the whole group instead of emptying it
#    SKIP_STEPS="01"               skip steps by number
#    DRY_RUN=true                  print every command instead of executing it
#    CONFIRM=yes                   non-interactive (you are sure)
#
#  Afterwards, if a Terraform state exists for these resources, run
#  destroy/90-reset-terraform-state.sh so Terraform does not try to recreate them.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
DELETE_RESOURCE_GROUP="${DELETE_RESOURCE_GROUP:-true}"

hr
warn "FULL TEARDOWN of cluster $CLUSTER_NAME in $RESOURCE_GROUP (subscription $SUBSCRIPTION_ID)"
if [[ "$DELETE_RESOURCE_GROUP" == "true" ]]; then
  warn "The resource group itself will be deleted at the end."
else
  warn "The resource group will be emptied but kept (DELETE_RESOURCE_GROUP=false)."
fi
confirm "$CLUSTER_NAME"
export CONFIRM=yes   # child scripts must not prompt again

STEPS=(01-destroy-kubernetes-workloads.sh 02-destroy-aks-cluster.sh)
if [[ "$DELETE_RESOURCE_GROUP" == "true" ]]; then
  STEPS+=(06-destroy-resource-group.sh)
else
  STEPS+=(03-destroy-disks.sh 04-destroy-networking.sh 05-destroy-platform-services.sh)
fi

for step in "${STEPS[@]}"; do
  num="${step:0:2}"
  # shellcheck disable=SC2086
  if in_list "$num" ${SKIP_STEPS:-}; then log "skipping $step (SKIP_STEPS)"; continue; fi
  hr; hr
  log "===> $step"
  bash "$ROOT_DIR/destroy/$step" || warn "$step reported errors — continuing with the next step"
done

hr; hr
ok "Teardown finished."
if [[ -f "$TF_DIR/terraform.tfstate" || -d "$TF_DIR/.terraform" ]]; then
  log "A Terraform working directory exists. Run ./destroy/90-reset-terraform-state.sh to drop the stale state."
fi
