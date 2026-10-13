#!/usr/bin/env bash
# =============================================================================
#  import/import-all.sh — run every import script in dependency order
# =============================================================================
#  Order matters only for readability of the generated files (each step's
#  `terraform plan -generate-config-out` picks up whatever import blocks have
#  no resource block yet). Helm runs last because a helm_release with an
#  unknown repository makes `terraform plan` fail until you fill it in.
#
#  Skip steps by number:   SKIP_STEPS="07 08" ./import/import-all.sh
#  Only write blocks:      SKIP_GENERATE=true ./import/import-all.sh
#                          (then run terraform plan -generate-config-out once yourself)
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config

STEPS=(
  01-import-resource-group.sh
  02-import-networking.sh
  03-import-identity.sh
  04-import-aks-cluster.sh
  05-import-disks.sh
  06-import-storage.sh
  07-import-acr.sh
  08-import-keyvault.sh
  09-import-monitoring.sh
  10-import-kubernetes-deployments.sh
  11-import-helm-releases.sh
)

# Fresh audit trail for a full run.
rm -f "$IMPORT_LOG"

for step in "${STEPS[@]}"; do
  num="${step:0:2}"
  # shellcheck disable=SC2086
  if in_list "$num" ${SKIP_STEPS:-}; then
    log "skipping $step (SKIP_STEPS)"
    continue
  fi
  hr; hr
  log "===> $step"
  bash "$ROOT_DIR/import/$step" || die "$step failed — fix the problem and re-run it alone, then continue with the next step"
done

hr; hr
log "All import scripts finished."
log "Next:"
log "  1. Review terraform/imports/*.tf      (what will be adopted)"
log "  2. Review terraform/generated/*.tf    (the HCL Terraform wrote; fix TODOs / remove read-only attrs)"
log "  3. ./import/90-apply-imports.sh       (terraform plan + apply -> state is created)"
log "  4. ./import/95-verify.sh              (terraform plan must show no changes)"
