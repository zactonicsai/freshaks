#!/usr/bin/env bash
# =============================================================================
#  destroy/terraform-destroy.sh — tear everything down THROUGH TERRAFORM
# =============================================================================
#  Use this after the import has been applied (state exists). Imported
#  resources have no `depends_on` links between them (generated HCL uses
#  literal IDs), so a plain `terraform destroy` would try to delete a VNet
#  while the cluster still uses it, or a disk while a pod still mounts it.
#  This script therefore destroys in STAGES, each one a targeted
#  `terraform destroy` built from `terraform state list`:
#
#    1. Kubernetes objects + Helm releases   (needs the cluster alive)
#    2. extra AKS node pools
#    3. the AKS cluster                      (Azure deletes the MC_ node RG with it)
#    4. managed disks + snapshots            (now detached, or already gone)
#    5. platform services                    (ACR, Key Vault, storage, monitoring, identities, RBAC)
#    6. networking                           (subnet links first, VNet last)
#    7. the resource group
#    8. anything left                        (plain terraform destroy)
#
#  DRY_RUN=true shows the targets per stage without deleting anything.
#  CONFIRM=yes  skips the prompt (used by destroy-all.sh is NOT this path;
#               this script is the Terraform alternative to destroy-all.sh).
#
#  terraform commands used:
#     terraform init                                  make sure providers/backend are ready
#     terraform state list                            every address in state
#     terraform destroy -target=<addr> ... -auto-approve   delete only the listed addresses (and their dependents)
#     terraform destroy -auto-approve                 final sweep
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
require_tools terraform
tf_write_tfvars

hr
warn "This will DESTROY every resource in the Terraform state for cluster $CLUSTER_NAME."
confirm "$CLUSTER_NAME"

cd "$TF_DIR" || die "cannot cd to $TF_DIR"
# Import blocks whose objects are being deleted would fail every later plan.
archive_import_blocks
run terraform init -input=false >/dev/null

# destroy_stage <title> <extended regex on state addresses>
destroy_stage() {
  local title="$1" regex="$2" addr
  local targets=()
  while IFS= read -r addr; do
    if [[ -n "$addr" ]]; then targets+=("-target=$addr"); fi
  done < <(terraform state list 2>/dev/null | grep -E "$regex" || true)
  hr
  if [[ ${#targets[@]} -eq 0 ]]; then
    log "Stage '$title': nothing in state"
    return 0
  fi
  log "Stage '$title': ${#targets[@]} resource(s)"
  printf '    %s\n' "${targets[@]#-target=}"
  run terraform destroy -input=false -auto-approve "${targets[@]}" \
    || warn "Stage '$title' reported errors — later stages may clean up; re-run if needed"
}

destroy_stage "Kubernetes workloads + Helm releases" '^(helm_release|kubernetes_)'
destroy_stage "AKS node pools"                       '^azurerm_kubernetes_cluster_node_pool\.'
destroy_stage "AKS cluster"                          '^(azurerm_kubernetes_cluster|azurerm_kubernetes_cluster_extension)\.'
destroy_stage "Disks and snapshots"                  '^(azurerm_managed_disk|azurerm_snapshot)\.'
destroy_stage "Platform services"                    '^(azurerm_monitor_|azurerm_log_analytics|azurerm_dashboard_grafana|azurerm_container_registry|azurerm_key_vault|azurerm_storage_|azurerm_role_assignment|azurerm_federated_identity_credential|azurerm_user_assigned_identity)'
destroy_stage "Networking — links and edge"          '^(azurerm_subnet_[a-z_]*_association|azurerm_nat_gateway_public_ip_association|azurerm_private_endpoint|azurerm_application_gateway|azurerm_lb|azurerm_private_dns_zone_virtual_network_link)\.'
destroy_stage "Networking — core"                    '^(azurerm_nat_gateway|azurerm_public_ip|azurerm_private_dns_zone|azurerm_dns_zone|azurerm_network_security_group|azurerm_route_table|azurerm_subnet|azurerm_virtual_network)\.'
destroy_stage "Resource group"                       '^azurerm_resource_group\.'

hr
log "Final sweep: terraform destroy (anything the stages did not match)"
run terraform destroy -input=false -auto-approve || warn "final destroy reported errors"

hr
remaining="$(terraform state list 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$remaining" -eq 0 ]]; then
  ok "State is empty — everything Terraform managed is gone."
else
  warn "$remaining resource(s) remain in state:"
  terraform state list | sed 's/^/    /'
fi
