#!/usr/bin/env bash
# =============================================================================
#  import/90-apply-imports.sh — turn the import blocks into Terraform STATE
# =============================================================================
#  Steps
#    1. sanity checks: import blocks exist, no helm TODOs left
#    2. terraform init                  download providers, initialise backend
#    3. terraform validate              catch HCL problems in generated/*.tf
#    4. terraform plan -out=import.tfplan   should read "N to import, 0 to add, 0 to change, 0 to destroy"
#    5. terraform apply import.tfplan   writes the state — nothing in Azure changes
#    6. archive terraform/imports/*.tf  import blocks are one-shot
#    7. terraform plan -detailed-exitcode   proves state == reality (exit 0) or shows drift (exit 2)
#
#  AUTO_APPROVE=true skips the confirmation prompt (CI usage).
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
require_tools terraform jq
tf_write_tfvars
cd "$TF_DIR" || die "cannot cd to $TF_DIR"

# --- 1. Sanity checks ----------------------------------------------------------
if ! ls imports/*.tf >/dev/null 2>&1; then
  die "No import blocks in terraform/imports/. Run the import scripts first."
fi
if grep -qs 'TODO-CHART-REPOSITORY-URL' generated/helm_releases.tf; then
  grep -n 'TODO-CHART-REPOSITORY-URL' generated/helm_releases.tf | head -n 5 >&2
  die "generated/helm_releases.tf still contains TODO chart repositories. Fill them in (or set HELM_REPO_MAP and re-run 11-import-helm-releases.sh)."
fi
total_blocks="$(cat imports/*.tf | grep -c '^import {' || true)"
log "$total_blocks import block(s) ready"

# --- 2. init ------------------------------------------------------------------
log "terraform init"
run terraform init -input=false

# --- 3. validate --------------------------------------------------------------
log "terraform validate"
if ! run terraform validate; then
  die "Validation failed. Typical fixes: delete read-only attributes from generated/*.tf, fill helm TODOs."
fi

# --- 4. plan ------------------------------------------------------------------
log "terraform plan -out=import.tfplan"
run terraform plan -input=false -out=import.tfplan
hr
log "Expected summary: '$total_blocks to import, 0 to add, 0 to change, 0 to destroy'."
log "Anything 'to change' means the generated HCL differs from reality; fix generated/*.tf and re-run."
log "Anything 'to destroy' — STOP and investigate."
hr

if [[ "${AUTO_APPROVE:-false}" != "true" && "$DRY_RUN" != "true" ]]; then
  printf 'Apply this plan? Type "yes": '
  read -r answer
  [[ "$answer" == "yes" ]] || die "Aborted — nothing was applied."
fi

# --- 5. apply (imports only; cloud resources are untouched) -------------------
log "terraform apply import.tfplan"
run terraform apply -input=false import.tfplan
rm -f import.tfplan

# --- 6. archive the one-shot import blocks ------------------------------------
archive_import_blocks

# --- 7. verify ----------------------------------------------------------------
log "terraform plan -detailed-exitcode  (0 = state matches reality, 2 = drift)"
set +e
run terraform plan -input=false -detailed-exitcode >"$OUT_DIR/plan-verify.log" 2>&1
rc=$?
set -e
case "$rc" in
  0) ok "State matches the real infrastructure. $(terraform state list | wc -l | tr -d ' ') resource(s) under management." ;;
  2) warn "State is created but 'terraform plan' still shows changes — see out/plan-verify.log and tune generated/*.tf (ignore_changes, computed fields)." ;;
  *) warn "terraform plan failed — see out/plan-verify.log" ;;
esac
